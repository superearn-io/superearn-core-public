// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICooldownVault } from "@superearn/interface/ICooldownVault.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StrategyParams } from "@superearn/interface/IVault.sol";
import { BaseStrategy } from "@yearn-vaults/BaseStrategy.sol";
import { IStrategyCooldownAware } from "@superearn/interface/IStrategyCooldownAware.sol";
import { TimelockExecutionLib } from "@superearn/core/lib/TimelockExecutionLib.sol";

/**
 * @title BaseCooldownStrategy
 * @notice Abstract base contract for strategies that interact with external vaults requiring cooldown periods
 * @dev This contract handles the coordination between CooldownVault predeposits and external vault redemptions.
 *      It manages the complex flow of:
 *      1. Requesting redemptions from external vaults
 *      2. Predepositing CooldownVaults for immediate liquidity
 *      3. Repaying predeposit debt once external redemptions are claimable
 *      Inheriting strategies must implement the abstract functions to integrate with specific external vaults.
 */
abstract contract BaseCooldownStrategy is IStrategyCooldownAware, BaseStrategy, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TimelockExecutionLib for TimelockExecutionLib.TimelockStorage;

    // === Custom Errors ===
    error InvalidExternalToken();
    error OnlyCooldownVault();
    error InvalidExternalRedeem();
    error InvalidDebtClaimState();
    error CannotRepayByFailedClaim();
    error ClaimAlreadyProcessed();
    error InsufficientUnderlyingBalance(uint256 requested, uint256 available);
    error ZeroAssets();
    error RepayAmountExceedsShortfall(uint256 requested, uint256 outstanding);
    error OutstandingPredepositDebt();

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 internal immutable AMOUNT_TO_SHARE_BUFFER;

    /// @notice Restricts function access to CooldownVault contract only
    modifier onlyCooldownVault() {
        if (msg.sender != address(cooldownVault)) revert OnlyCooldownVault();
        _;
    }

    /// @notice Maps predeposit IDs to their corresponding external vault redeem indexes
    mapping(uint256 predepositId => uint256 externalRedeemIndex) public externalRedeemIndexes;

    /// @notice Token received from external vault redemptions (usually same as want().underlyingToken())
    IERC20 public immutable externalShareToken;
    IERC20 public immutable externalUnderlyingToken;
    ICooldownVault public immutable cooldownVault;

    /// @notice Default: 100 tokens (e.g., 100 USDT)
    uint256 public shortfallTolerance;
    /// @notice Total shortfall of the predeposit debt
    /// @notice Timelock execution storage (pendingExecution, allowedTargets, timelockDelay)
    TimelockExecutionLib.TimelockStorage internal _timelockStorage;

    /// @notice Accumulated shortfall from predeposit repayments (mirrors cooldownVault.strategyShortfall)
    /// @dev This is only the unpaid portion when repayPredepositDebt() underpays; it is not the full
    /// predeposit debt. Starts at 0, increases by (expected - claimed), and is cleared when
    /// repayRemainingPredepositDebt() calls cooldownVault.retrieveShortfall(). Used to avoid
    /// overstating assets in estimatedTotalAssets() while the vault still records the shortfall inside
    /// strategyDebtOutstanding.
    uint256 public remainingPredepositDebt;

    /**
     * @notice Initializes the base cooldown strategy
     * @param _vault Address of the Yearn vault
     * @param _externalShareToken Address of the external vault's share token
     * @param _externalUnderlyingToken Address of the token received from external vault redemptions
     * @dev Verifies that external underlying token matches CooldownVault's underlying
     */
    constructor(address _vault, address _externalShareToken, address _externalUnderlyingToken) BaseStrategy(_vault) {
        if (_externalShareToken == address(0)) revert InvalidExternalToken();
        externalShareToken = IERC20(_externalShareToken);

        externalUnderlyingToken = IERC20(_externalUnderlyingToken);

        cooldownVault = ICooldownVault(address(want));

        if (_externalUnderlyingToken != cooldownVault.asset()) {
            revert InvalidExternalToken();
        }

        shortfallTolerance = 100 * 10 ** IERC20Metadata(address(want)).decimals();

        _timelockStorage.timelockDelay = 0 days; // OpenZeppelin standard is 2 days
    }

    // ============================================
    // ABSTRACT FUNCTIONS
    // ============================================

    /**
     * @notice Returns the cooldown period of the external vault
     * @return cooldownPeriod The cooldown period in seconds
     */
    function getCooldownPeriod() public view virtual override returns (uint256 cooldownPeriod);

    /**
     * @notice Requests a deposit of assets into the external vault
     * @param assets Amount of underlying tokens to deposit
     * @return success True if the deposit request was successful
     * @return shares Number of external vault shares received from the deposit
     * @return filledAssets Amount of underlying tokens filled from the deposit
     * @dev This function is called internally to invest idle assets into the external vault.
     *      The implementation should handle the actual deposit interaction with the external vault.
     *      Inheriting contracts must complete the implementation after the beforeExternalDeposit check.
     *      Example: In StrategyAvalonUSDTVault, this mints sUSDT shares from the Avalon vault.
     */
    function requestDeposit(uint256 assets)
        internal
        virtual
        returns (bool success, uint256 shares, uint256 filledAssets)
    {
        if (!beforeExternalDeposit(assets)) return (false, 0, 0);
        // Comment: Inheriting contracts must complete the implementation
    }

    /**
     * @notice Requests a redemption of shares from the external vault
     * @param shares Number of external vault shares to redeem
     * @return success True if the redemption request was successful
     * @return redeemId The unique identifier of the redemption request in the external vault
     * @return redeemUnderlyingAmount The amount of underlying tokens to be received upon redemption
     * @return cooldownPeriod The cooldown period in seconds
     * @dev This function initiates the cooldown period for withdrawing from the external vault.
     *      The implementation should handle the actual redemption request with the external vault.
     *      Inheriting contracts must complete the implementation after the beforeExternalRedeem check.
     *      Example: In StrategyAvalonUSDTVault, this burns sUSDT shares and registers a redemption request.
     */
    function requestRedeem(uint256 shares)
        internal
        virtual
        returns (bool success, uint256 redeemId, uint256 redeemUnderlyingAmount, uint256 cooldownPeriod)
    {
        if (!beforeExternalRedeem(shares)) return (false, 0, 0, 0);
        // Comment: Inheriting contracts must complete the implementation
    }

    /**
     * @notice Claims a completed redemption from the external vault
     * @param redeemIndex The index/ID of the redemption to claim
     * @dev This internal function makes permissive requests
     *      Validation should be handled where this function is used
     */
    function requestClaim(uint256 redeemIndex) internal virtual returns (bool success, uint256 claimedAmount);

    /**
     * @notice Converts assets to shares for the external DeFi vault this strategy integrates with
     * @param assets Amount of underlying tokens to convert
     * @return shares Equivalent amount of external vault shares
     * @dev If the external vault is ERC4626-compliant or supports precise rounding,
     *      this function should use Math.Rounding.Floor (returns fewer shares, favorable to vault)
     */
    function previewDeposit(uint256 assets) public view virtual override returns (uint256 shares);

    /// @notice See previewDeposit. Uses Math.Rounding.Ceil (requires more assets, favorable to vault)
    function previewMint(uint256 shares) public view virtual override returns (uint256 assets);

    /// @notice See previewDeposit. Uses Math.Rounding.Ceil (requires more shares, favorable to vault)
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256 shares);

    /// @notice See previewDeposit. Uses Math.Rounding.Floor (returns fewer assets, favorable to vault)
    function previewRedeem(uint256 shares) public view virtual override returns (uint256 assets);

    /**
     * @notice Gets the last redemption index from external vault
     * @return The index/ID of the most recent redemption request
     * @dev Used to track which external redemption corresponds to a predeposit
     */
    function getLastRedeemIndex() internal view virtual returns (uint256);

    /**
     * @notice Gets detailed information about a specific redemption request
     * @param redeemIndex The index/ID of the redemption to query
     * @return redeemId The unique identifier of the redemption request
     * @return redeemTimestamp The timestamp when the redemption was requested
     * @return redeemUser The address that initiated the redemption
     * @return redeemUnderlyingAmount The amount of underlying tokens to be redeemed
     * @return redeemIsDone Whether the redemption has been completed
     * @dev Implementation should query the external vault for redemption details
     */
    function getRedeemDetail(uint256 redeemIndex)
        public
        view
        virtual
        override
        returns (
            uint256 redeemId,
            uint256 redeemTimestamp,
            address redeemUser,
            uint256 redeemUnderlyingAmount,
            bool redeemIsDone
        );

    /**
     * @notice Gets the supply cap and available capacity from the external vault
     * @return supplyAssetsCap The maximum amount that can be supplied to the external vault
     * @return availableAssets The amount still available to be supplied before reaching the cap
     */
    function getSupplyCap() public view virtual override returns (uint256 supplyAssetsCap, uint256 availableAssets);

    /**
     * @notice Checks if the external vault redemption linked to a predeposit has been claimed
     * @param predepositId The predeposit ID to check
     * @return isClaimed True if the external redemption was already claimed from the external vault
     * @dev This function is used for monitoring and debugging purposes only.
     *
     *      IMPORTANT: This strategy does NOT support permissionless claim protocols directly.
     *      If the external protocol allows anyone to claim redemptions (permissionless claims),
     *      you MUST use an intermediate Escrow/Swapper contract that:
     *      1. Receives the permissionless claim on behalf of the strategy
     *      2. Holds assets until strategy explicitly pulls them via claimSwapToVaultAsset()
     *      3. Ensures atomic claim + transfer during repayPredepositDebt()
     *
     *      Direct permissionless claims to strategy cause asset double-counting in
     *      estimatedTotalAssets() (once as CooldownVault shares from predeposit, once as
     *      externalUnderlyingToken.balanceOf), leading to incorrect profit/loss calculations
     *      during harvest() and distorted Yearn Vault share prices.
     *
     *      See docs/PERMISSIONLESS_CLAIM_ARCHITECTURE.md for detailed architecture guidance.
     */
    function isPredepositAlreadyClaimed(uint256 predepositId) external view virtual override returns (bool isClaimed);

    /**
     * @notice Checks if a predeposit debt can be retrieved from external vault
     * @param predepositId The predeposit ID to check
     * @return isRetrievable True if the corresponding external redemption has completed its cooldown
     */
    function predepositDebtRetrievable(uint256 predepositId)
        external
        view
        virtual
        override
        returns (bool isRetrievable);

    // ============================================
    // CORE FUNCTIONS
    // ============================================

    /**
     * @notice Validates whether a deposit to the external vault should proceed
     * @param assets Amount of underlying tokens to deposit
     * @return valid True if the deposit should proceed, false otherwise
     * @dev This hook is called before executing requestDeposit to allow strategy-specific validation.
     *      Implementations can check minimum amounts, supply caps, or other conditions.
     *      Example: In StrategyAvalonUSDTVault, validates that assets >= 1 USDT (Avalon's minimum).
     */
    function beforeExternalDeposit(uint256 assets) internal view virtual returns (bool valid);

    /**
     * @notice Validates whether a redemption from the external vault should proceed
     * @param shares Number of external vault shares to redeem
     * @return valid True if the redemption should proceed, false otherwise
     * @dev This hook is called before executing requestRedeem to allow strategy-specific validation.
     *      Implementations can check minimum amounts, availability, or other conditions.
     *      Example: In StrategyAvalonUSDTVault, validates that shares >= 1.0 sUSDT (Avalon's minimum).
     */
    function beforeExternalRedeem(uint256 shares) internal view virtual returns (bool valid);

    /**
     * @notice Handles the preminting of CooldownVaults with coordinated external redemption
     * @param sharesNeeded Maximum amount of CooldownVault shares to premint
     * @dev The function name uses "premint" instead of "predeposit" to maintain consistency
     *      with ERC4626 standard naming conventions. In ERC4626, when the parameter represents
     *      shares (as opposed to assets), the function uses "mint" rather than "deposit".
     *      This naming choice intentionally aligns with the ERC4626 pattern for share-based operations.
     *      This function:
     *      1. Initiates redemption from external vault
     *      2. Records the redemption index
     *      3. Predeposits CooldownVaults for immediate liquidity
     *      4. Links predeposit ID to external redemption for future debt repayment
     */
    function premintCooldownVault(uint256 sharesNeeded)
        internal
        virtual
        returns (uint256 predepositId, uint256 preShares, uint256 lossShares)
    {
        // Request redeem from external vault
        bool redeemSuccess;
        uint256 redeemIndex;
        uint256 redeemUsdt;
        uint256 cooldownPeriod;
        {
            // When requesting based on shares, the actual amount received is often less than expected.
            // Receiving slightly more than this is not an issue, so we add a buffer of 10 amount.
            uint256 _needUsdt = cooldownVault.previewMint(sharesNeeded);
            uint256 _needSusdt = previewWithdraw(_needUsdt + AMOUNT_TO_SHARE_BUFFER);
            uint256 _susdtBalance = externalShareToken.balanceOf(address(this));
            uint256 shares = Math.min(_needSusdt, _susdtBalance);

            (redeemSuccess, redeemIndex, redeemUsdt, cooldownPeriod) = requestRedeem(shares);
            if (!redeemSuccess) return (0, 0, 0);
        }
        if (!emergencyExit && redeemIndex == 0) revert InvalidExternalRedeem();

        // Normal deposit without predeposit - for vaults with no cooldown period (like standard ERC4626)
        if (cooldownPeriod == 0) {
            externalUnderlyingToken.forceApprove(address(cooldownVault), redeemUsdt);
            preShares = cooldownVault.deposit(redeemUsdt, address(this));
            lossShares = sharesNeeded > preShares ? (sharesNeeded - preShares) : 0;
            return (0, preShares, lossShares);
        }

        // Predeposit cooldown tokens
        (predepositId, preShares) = cooldownVault.predeposit(redeemUsdt);
        if (predepositId == 0) return (0, 0, 0);
        lossShares = sharesNeeded > preShares ? (sharesNeeded - preShares) : 0;

        externalRedeemIndexes[predepositId] = redeemIndex;

        emit Preminted(predepositId, redeemUsdt, preShares, redeemIndex);
    }

    /**
     * @notice Repays debt for a predeposited CooldownVault by claiming from external vault
     * @param predepositId The ID of the predeposit to repay
     * @dev This function is called by CooldownVault contract when a user's cooldown expires.
     *      The CooldownVault contract should verify predepositDebtRetrievable before calling.
     *      Process:
     *      1. Claims the completed redemption from external vault
     *      2. Transfers claimed tokens to CooldownVault contract
     *      3. CooldownVault then transfers to the user
     */
    function repayPredepositDebt(uint256 predepositId)
        external
        virtual
        override
        onlyCooldownVault
        nonReentrant
        returns (uint256 repayAmount)
    {
        (,, uint256 predepositDebt,,, bool predepositRepaymentFinished) = cooldownVault.predepositRequests(predepositId);
        if (predepositRepaymentFinished) {
            revert InvalidDebtClaimState();
        }

        // Claim from external vault
        uint256 redeemIndex = externalRedeemIndexes[predepositId];
        (,,,, bool redeemIsDone) = getRedeemDetail(redeemIndex);

        // SECURITY: Strategy must NOT receive assets via permissionless claim.
        // If external protocol supports permissionless claims, use an Escrow/Swapper
        // contract to receive claims and pull assets atomically during repayment.
        // Direct permissionless claims cause asset double-counting in estimatedTotalAssets().
        if (redeemIsDone) revert ClaimAlreadyProcessed();

        (bool claimSuccess, uint256 claimedAmount) = requestClaim(redeemIndex);
        if (!claimSuccess) revert CannotRepayByFailedClaim();

        // Transfer to cooldown token
        if (claimedAmount < predepositDebt) {
            repayAmount = claimedAmount;
            remainingPredepositDebt += predepositDebt - claimedAmount;
        } else {
            repayAmount = predepositDebt;
        }

        externalUnderlyingToken.safeTransfer(msg.sender, repayAmount);
        emit PredepositDebtRepaid(predepositId, repayAmount);
    }

    /**
     * @notice Repays accumulated shortfall from previous predeposit debt repayments
     * @param repayAmount Amount of underlying tokens to repay toward the shortfall
     */
    function repayRemainingPredepositDebt(uint256 repayAmount) internal virtual {
        uint256 balance = externalUnderlyingToken.balanceOf(address(this));
        if (repayAmount == 0) revert ZeroAssets();
        if (repayAmount > remainingPredepositDebt) {
            revert RepayAmountExceedsShortfall(repayAmount, remainingPredepositDebt);
        }
        if (repayAmount > balance) {
            revert InsufficientUnderlyingBalance(repayAmount, balance);
        }

        externalUnderlyingToken.safeIncreaseAllowance(address(cooldownVault), repayAmount);
        cooldownVault.retrieveShortfall(repayAmount);
        remainingPredepositDebt -= repayAmount;
        emit RemainingPredepositDebtRepaid(repayAmount);
    }

    /// @dev Deposit surplus underlying to CooldownVault, keeping only what's needed for predeposit debt.
    /// @notice Raw underlying can accumulate when OriginVault redemptions pay out before we repatriate to CooldownVault
    ///         (e.g., NAV drift between premint and OriginVault fulfillment). This helper deposits only the true
    ///         surplus while holding back enough to satisfy pending predeposit debt to CooldownVault.
    function _redepositUnderlyingSurplus() internal virtual {
        uint256 underlyingBal = externalUnderlyingToken.balanceOf(address(this));
        if (underlyingBal == 0) return;

        uint256 reserve = cooldownVault.strategyDebtOutstanding(address(this));
        if (underlyingBal <= reserve) return;
        uint256 surplus = underlyingBal - reserve;

        externalUnderlyingToken.forceApprove(address(cooldownVault), surplus);
        cooldownVault.deposit(surplus, address(this));
    }

    // ============================================
    // GOVERNANCE FUNCTIONS
    // ============================================

    /**
     * @notice Allows authorized users to initiate an emergency redemption from the external vault
     * @param shares Number of external vault shares to redeem
     * @return success True if the redemption request was successful
     * @return redeemId The unique identifier of the redemption request
     * @return redeemUnderlyingAmount The amount of underlying tokens to be received
     * @return cooldownPeriod The cooldown period in seconds
     * @dev Only callable by authorized addresses (governance/management)
     */
    function emergencyRedeem(uint256 shares)
        external
        virtual
        override
        onlyGovernance
        returns (bool success, uint256 redeemId, uint256 redeemUnderlyingAmount, uint256 cooldownPeriod)
    {
        return requestRedeem(shares);
    }

    /**
     * @notice Allows authorized users to claim a completed redemption from the external vault
     * @param redeemIndex The index/ID of the redemption to claim
     * @return success True if the claim was successful
     * @return claimedAmount The amount of underlying tokens claimed
     * @dev External function restricted to authorized addresses for emergency situations
     */
    function emergencyClaim(uint256 redeemIndex)
        external
        virtual
        override
        onlyGovernance
        returns (bool success, uint256 claimedAmount)
    {
        return requestClaim(redeemIndex);
    }

    /// @notice Governance function to manually repay shortfall. See repayRemainingPredepositDebt()
    function emergencyRepayRemainingPredepositDebt(uint256 repayAmount) external virtual onlyGovernance {
        repayRemainingPredepositDebt(repayAmount);
    }

    /**
     * @notice Updates the shortfall tolerance
     * @dev Only callable by governance
     * @param newTolerance The new shortfall tolerance value
     */
    function setShortfallTolerance(uint256 newTolerance) external virtual onlyGovernance {
        uint256 oldTolerance = shortfallTolerance;
        shortfallTolerance = newTolerance;

        emit ShortfallToleranceUpdated(oldTolerance, newTolerance);
    }

    /**
     * @notice Submit arbitrary external calls for future execution (supports batch calls)
     * @dev Delegates to TimelockExecutionLib for logic. See library for full documentation.
     * @param targets Array of contract addresses to call (must be whitelisted, cannot be self)
     * @param calldatas Array of encoded function call data
     */
    function submitExecution(
        address[] calldata targets,
        bytes[] calldata calldatas
    )
        external
        virtual
        override
        onlyGovernance
    {
        bytes4[] memory allowedSelfCallSelectors = new bytes4[](1);
        allowedSelfCallSelectors[0] = this._setTimelockDelay.selector;

        _timelockStorage.submitExecution(targets, calldatas, allowedSelfCallSelectors);
    }

    /**
     * @notice Execute the pending external calls
     * @dev Delegates to TimelockExecutionLib for logic. See library for full documentation.
     * @return success Whether all external calls succeeded
     * @return returnData Array of return data from each external call
     */
    function acceptExecution()
        external
        virtual
        override
        onlyGovernance
        returns (bool success, bytes memory returnData)
    {
        return _timelockStorage.acceptExecution();
    }

    /**
     * @notice Cancel the pending execution
     * @dev Delegates to TimelockExecutionLib for logic. See library for full documentation.
     */
    function cancelExecution() external virtual override onlyAuthorized {
        _timelockStorage.cancelExecution();
    }

    /**
     * @notice Add or remove a target address from the whitelist
     * @dev Delegates to TimelockExecutionLib for logic. See library for full documentation.
     * @param target The address to update in the whitelist
     * @param allowed Whether the target should be allowed
     */
    function setAllowedTarget(address target, bool allowed) external virtual override onlyGovernance {
        _timelockStorage.setAllowedTarget(target, allowed);
    }

    /**
     * @notice Updates the timelock delay for governance executions
     * @dev Only callable by the contract itself through submitExecution() -> acceptExecution() flow.
     * @param newDelay The new timelock delay in seconds (must be between MIN and MAX)
     */
    function _setTimelockDelay(uint256 newDelay) external virtual {
        if (msg.sender != address(this)) {
            revert TimelockExecutionLib.InvalidExecutionState("ONLY_SELF");
        }
        _timelockStorage.setTimelockDelay(newDelay);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Returns the pending execution details
    function pendingExecution() external view returns (TimelockExecutionLib.PendingExecution memory) {
        return _timelockStorage.pendingExecution;
    }

    /// @notice Returns whether a target address is allowed for execution
    function allowedTargets(address target) external view returns (bool) {
        return _timelockStorage.allowedTargets[target];
    }

    /// @notice Returns the current timelock delay
    function timelockDelay() external view returns (uint256) {
        return _timelockStorage.timelockDelay;
    }

    /**
     * @notice Calculates the utilization rate of the strategy's assets
     * @return The utilization rate in basis points (10000 = 100%)
     * @dev Utilization rate = (totalAssets - pendingInvested) / totalAssets * 10000
     *      where pendingInvested is the amount of CooldownVaults waiting to be invested
     */
    function getUtilizationRate() external view virtual override returns (uint256) {
        uint256 totalAssets = estimatedTotalAssets();
        uint256 pendingInvested = want.balanceOf(address(this));

        if (totalAssets == 0) return 0;
        // Floor numerator at zero: during shortfall or partial redemption the idle
        // want balance can exceed estimatedTotalAssets(), which would otherwise
        // underflow and revert (e.g. at adjustPosition()'s final event emission).
        uint256 invested = totalAssets > pendingInvested ? totalAssets - pendingInvested : 0;
        return Math.mulDiv(invested, BASIS_POINTS, totalAssets);
    }

    function getStrategyParams() internal view virtual returns (StrategyParams memory) {
        return vault.strategies(address(this));
    }

    /**
     * @notice Estimates total assets managed by this strategy (in CooldownVault shares)
     * @return Total estimated assets, accounting for shortfall
     */
    function estimatedTotalAssets() public view virtual override returns (uint256) {
        uint256 pendingInvested = want.balanceOf(address(this));

        uint256 previewInWant;
        {
            uint256 underlyingToPreview = externalUnderlyingToken.balanceOf(address(this));

            uint256 shareBalance = externalShareToken.balanceOf(address(this));
            underlyingToPreview += previewRedeem(shareBalance);

            previewInWant = cooldownVault.previewDeposit(underlyingToPreview);
        }

        uint256 totalAsset = pendingInvested + previewInWant;
        if (remainingPredepositDebt > totalAsset) {
            return 0;
        } else {
            return totalAsset - remainingPredepositDebt;
        }
    }

    /// @dev Migration guard: ensure this strategy has no outstanding predeposit debt or shortfall
    function _requireNoOutstandingDebt() internal view {
        if (cooldownVault.strategyShortfall(address(this)) > 0) revert OutstandingPredepositDebt();
        if (cooldownVault.strategyDebtOutstanding(address(this)) > 0) revert OutstandingPredepositDebt();
    }
}
