// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { BaseCooldownStrategy } from "@superearn/core/strategy/BaseCooldownStrategy.sol";
import { OriginVault } from "@superearn/v2/core/vaults/OriginVault.sol";

/**
 * @title StrategyOriginVault
 * @notice Generic strategy for OriginVault with two-step redemption flow
 * @dev Implements BaseCooldownStrategy for OriginVault that follows the
 *      async redeem/claim pattern (requestRedeem -> fulfill -> claim)
 */
contract StrategyOriginVault is BaseCooldownStrategy {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // ============================================
    // ERRORS
    // ============================================

    error InvalidVaultAddress();
    error InsufficientClaimableShares();
    error MigrationInProgress();
    error InvalidCooldownPeriod();
    error NoActiveRedemptions();
    error InvalidRedeemIndex();
    error RedemptionAlreadyClaimed();
    error RedemptionNotClaimable();
    error PremintFailed();

    // ============================================
    // STATE VARIABLES
    // ============================================

    OriginVault public immutable originVault;
    uint256 private immutable oneAsset;
    uint256 public cooldownPeriod;

    // Redemption tracking
    mapping(uint256 => RedemptionRequest) public redemptionRequests;
    uint256 public nextRedemptionId = 1;

    /// @notice Total shares currently locked in active redemption requests
    uint256 public totalSharesInRedemption;

    /// @notice Set of active redemption IDs for efficient iteration
    EnumerableSet.UintSet private activeRedemptionIds;

    /// @notice Tracks whether a redemption is backed by a predeposit (created via premintCooldownVault)
    /// @dev Used to identify unbacked redemptions (from emergencyRedeem or zero predeposit) at claim time
    mapping(uint256 => bool) public isBackedRedemption;

    /// @notice Total shares in unbacked redemptions (emergencyRedeem or zero predeposit)
    /// @dev Incremented in emergencyRedeem, decremented in requestClaim for unbacked redemptions
    uint256 public totalUnbackedRedemptionShares;

    /// @notice Maximum reserve ratio (10% of total assets)
    uint256 public constant MAX_RESERVE_RATIO_BPS = 1000;

    /// @notice Reserve ratio in basis points (0 = no reserve, 100 = 1%)
    uint256 public reserveRatioBps;

    // ============================================
    // STRUCTS
    // ============================================

    struct RedemptionRequest {
        uint256 shares;
        uint256 timestamp;
        uint256 expectedAssets; // Tracks initial expectation, overwritten with actual amount once claimed
        bool isClaimed; // True only after redeem() succeeds and underlying assets are in strategy custody
        uint256 vaultRequestId;
    }

    // ============================================
    // EVENTS
    // ============================================

    event RedemptionRequested(
        uint256 indexed strategyRedeemId, uint256 indexed vaultRequestId, uint256 shares, uint256 expectedAssets
    );
    event RedemptionClaimed(uint256 indexed strategyRedeemId, uint256 claimedAmount);
    event EmergencyClaim(uint256 indexed redeemId, uint256 amount);
    event DepositSuccessful(uint256 assets, uint256 shares);
    event DepositFailed(uint256 assets, bytes reason);
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event ForceMigrationInitiated(address indexed newStrategy, uint256 activeRedemptionsCount);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initializes the StrategyOriginVault with OriginVault integration
     * @param _vault Address of the Yearn vault that will manage this strategy
     * @param _originVault Address of the OriginVault
     * @param _cooldownPeriod Initial cooldown period in seconds (can be updated later)
     * @dev Sets up the OriginVault instance and configures strategy parameters
     */
    constructor(
        address _vault,
        address _originVault,
        uint256 _cooldownPeriod
    )
        BaseCooldownStrategy(_vault, _originVault, OriginVault(payable(_originVault)).asset())
    {
        if (_originVault == address(0)) revert InvalidVaultAddress();
        if (_cooldownPeriod == 0) revert InvalidCooldownPeriod();

        originVault = OriginVault(payable(_originVault));

        // Set with OriginVault as a reference:
        // share and asset conversions perform mulDiv(..., Rounding.Floor) with +1 in denominator
        AMOUNT_TO_SHARE_BUFFER = 1;

        cooldownPeriod = _cooldownPeriod;

        minReportDelay = 0;
        maxReportDelay = 7 days;

        uint8 assetDecimals = IERC20Metadata(originVault.asset()).decimals();

        oneAsset = 10 ** assetDecimals;
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    function name() external pure override returns (string memory) {
        return "StrategyOriginVault";
    }

    function setCooldownPeriod(uint256 _newCooldownPeriod) external onlyGovernance {
        // Async redemption flow depends on a non-zero cooldown; zero would cause unexpected behavior.
        if (_newCooldownPeriod == 0) revert InvalidCooldownPeriod();
        uint256 oldPeriod = cooldownPeriod;
        cooldownPeriod = _newCooldownPeriod;
        emit CooldownPeriodUpdated(oldPeriod, _newCooldownPeriod);
    }

    /// @notice Updates the reserve ratio for want shares reserve
    /// @param newRatioBps The new reserve ratio in basis points (0 = disabled, 100 = 1%)
    function setReserveRatio(uint256 newRatioBps) external onlyGovernance {
        if (newRatioBps > MAX_RESERVE_RATIO_BPS) revert InvalidReserveRatio();
        uint256 oldRatioBps = reserveRatioBps;
        reserveRatioBps = newRatioBps;
        emit ReserveRatioUpdated(oldRatioBps, newRatioBps);
    }

    error InvalidReserveRatio();

    event ReserveRatioUpdated(uint256 oldRatioBps, uint256 newRatioBps);

    // ============================================
    // ABSTRACT FUNCTION IMPLEMENTATIONS
    // ============================================

    function getCooldownPeriod() public view virtual override returns (uint256) {
        return cooldownPeriod;
    }

    function requestDeposit(uint256 assets)
        internal
        virtual
        override
        returns (bool success, uint256 shares, uint256 filledAssets)
    {
        if (!beforeExternalDeposit(assets)) return (false, 0, 0);
        //if (originVault.maxDeposit(address(this)) == 0) return (false, 0, 0);

        externalUnderlyingToken.forceApprove(address(originVault), assets);
        try originVault.deposit(assets, address(this)) returns (uint256 sharesReceived) {
            success = true;
            shares = sharesReceived;
            filledAssets = assets;

            emit DepositSuccessful(assets, shares);
        } catch (bytes memory reason) {
            externalUnderlyingToken.forceApprove(address(originVault), 0);
            success = false;
            emit DepositFailed(assets, reason);
        }
    }

    function requestRedeem(uint256 shares)
        internal
        virtual
        override
        returns (bool success, uint256 redeemId, uint256 redeemUnderlyingAmount, uint256 _cooldownPeriod)
    {
        if (!beforeExternalRedeem(shares)) return (false, 0, 0, 0);

        // Note: The OriginVault locks the redemption in shares at request time.
        // The actual assets are only received after fulfillment + cooldown. Any
        // gap between the expected assets and what is received must be reconciled
        // by governance/strategy (e.g., topping up before user claims) to honor
        // the locked redemption amount recorded in CooldownVault.
        try originVault.requestRedeem(shares, address(this), address(this)) returns (uint256 vaultRequestId) {
            // OriginVault requestRedeem transfers shares from owner to vault internally
            // We don't need to verify transfer - the vault handles it
            // If the call succeeded, the redemption request was accepted

            success = true;
            redeemId = nextRedemptionId++;

            redeemUnderlyingAmount = originVault.convertToAssets(shares);

            redemptionRequests[redeemId] = RedemptionRequest({
                shares: shares,
                timestamp: block.timestamp,
                expectedAssets: redeemUnderlyingAmount,
                isClaimed: false,
                vaultRequestId: vaultRequestId
            });

            totalSharesInRedemption += shares;
            activeRedemptionIds.add(redeemId);

            emit RedemptionRequested(redeemId, vaultRequestId, shares, redeemUnderlyingAmount);
        } catch {
            externalShareToken.forceApprove(address(originVault), 0);
            success = false;
        }

        _cooldownPeriod = getCooldownPeriod();
    }

    function requestClaim(uint256 redeemIndex)
        internal
        virtual
        override
        returns (bool success, uint256 claimedAmount)
    {
        RedemptionRequest storage request = redemptionRequests[redeemIndex];
        if (request.shares == 0) revert InvalidRedeemIndex();
        if (request.isClaimed) revert RedemptionAlreadyClaimed();

        uint256 claimableShares = _claimableShares(request);
        if (!_isRedemptionClaimable(request, claimableShares)) revert InsufficientClaimableShares();

        uint256 beforeBalance = externalUnderlyingToken.balanceOf(address(this));

        // Claim the redemption using vaultRequestId to get exact fulfilledAssets
        // This ensures claimedAmount == predepositDebt and prevents remainingPredepositDebt issues
        originVault.redeem(request.vaultRequestId, address(this), address(this));

        claimedAmount = externalUnderlyingToken.balanceOf(address(this)) - beforeBalance;

        request.isClaimed = true;
        request.expectedAssets = claimedAmount;

        totalSharesInRedemption -= request.shares;
        activeRedemptionIds.remove(redeemIndex);

        // Decrement unbacked counter if this was an emergency redemption
        if (!isBackedRedemption[redeemIndex]) {
            totalUnbackedRedemptionShares -= request.shares;
        }
        delete isBackedRedemption[redeemIndex];

        emit RedemptionClaimed(redeemIndex, claimedAmount);

        success = true;
    }

    /**
     * @dev Delegates to yield source vault for proper rounding (Floor)
     *      previewDeposit works for sync deposit in OriginVault
     */
    function previewDeposit(uint256 assets) public view virtual override returns (uint256 shares) {
        return originVault.previewDeposit(assets);
    }

    /**
     * @dev Delegates to yield source vault for proper rounding (Ceil)
     *      previewMint works for sync mint in OriginVault
     */
    function previewMint(uint256 shares) public view virtual override returns (uint256 assets) {
        return originVault.previewMint(shares);
    }

    /**
     * @dev Uses convertToShares because OriginVault (async vault)
     *      doesn't have previewWithdraw since redemption amount depends on fulfillment timing.
     *      Note: This loses Ceil rounding, but is acceptable for strategy's estimation purposes.
     */
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256 shares) {
        return originVault.convertToShares(assets);
    }

    /**
     * @dev Uses convertToAssets because OriginVault (async vault)
     *      doesn't have previewRedeem since redemption amount depends on fulfillment timing.
     *      Note: This uses default rounding (Floor), which is correct for previewRedeem.
     */
    function previewRedeem(uint256 shares) public view virtual override returns (uint256 assets) {
        return originVault.convertToAssets(shares);
    }

    function getLastRedeemIndex() internal view virtual override returns (uint256) {
        return nextRedemptionId - 1;
    }

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
        )
    {
        RedemptionRequest storage request = redemptionRequests[redeemIndex];

        if (request.shares == 0) {
            return (redeemIndex, request.timestamp, address(this), 0, false);
        }

        uint256 redeemedAssets = request.expectedAssets;

        // `redeemIsDone` returns true ONLY after the strategy has called redeem() and received assets.
        // Use isRedemptionClaimable() to distinguish requests that finished their cooldown but are unclaimed.
        return (redeemIndex, request.timestamp, address(this), redeemedAssets, request.isClaimed);
    }

    function getSupplyCap() public view virtual override returns (uint256 supplyAssetsCap, uint256 availableAssets) {
        availableAssets = originVault.maxDeposit(address(this));
        supplyAssetsCap = availableAssets;
    }

    function isPredepositAlreadyClaimed(uint256 predepositId) external view virtual override returns (bool isClaimed) {
        uint256 redeemIndex = externalRedeemIndexes[predepositId];
        if (redeemIndex == 0) return false;

        RedemptionRequest storage request = redemptionRequests[redeemIndex];
        return request.isClaimed;
    }

    /// @notice Returns true once the external vault finished its cooldown and the strategy can pull assets via redeem()
    /// @dev Distinct from `isPredepositAlreadyClaimed`, which tracks whether redeem() already ran and funds are on the
    /// strategy
    function predepositDebtRetrievable(uint256 predepositId) external view virtual override returns (bool) {
        uint256 redeemIndex = externalRedeemIndexes[predepositId];
        if (redeemIndex == 0) return false;

        RedemptionRequest storage request = redemptionRequests[redeemIndex];
        if (request.shares == 0) return false;
        if (request.isClaimed) return false;

        uint256 claimableShares = _claimableShares(request);
        return _isRedemptionClaimable(request, claimableShares);
    }

    function ethToWant(uint256 /* _amtInWei */ ) public view virtual override returns (uint256) {
        return 0;
    }

    function beforeExternalDeposit(uint256 assets) internal view virtual override returns (bool valid) {
        // previewDeposit works for sync deposit in OriginVault
        valid = originVault.previewDeposit(assets) > 0;
    }

    function beforeExternalRedeem(uint256 shares) internal view virtual override returns (bool valid) {
        // NOTE: Cannot use previewRedeem() here because OriginVault (async vault)
        // doesn't have previewRedeem since redemption amount depends on fulfillment timing.
        // Use convertToAssets() instead for basic validation.
        valid = originVault.convertToAssets(shares) > 0;
    }

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /// @notice Emergency redemption without predeposit backing
    /// @dev Overrides base to track unbacked redemption shares for estimatedTotalAssets()
    function emergencyRedeem(uint256 shares)
        external
        override
        onlyGovernance
        returns (bool success, uint256 redeemId, uint256 redeemUnderlyingAmount, uint256 _cooldownPeriod)
    {
        (success, redeemId, redeemUnderlyingAmount, _cooldownPeriod) = requestRedeem(shares);
        if (success) {
            // Track unbacked shares - isBackedRedemption stays false (default)
            totalUnbackedRedemptionShares += shares;
        }
    }

    /// @notice Emergency claim passthrough with explicit event and warning about double-counting
    /// @dev IMPORTANT: DOUBLE-COUNTING RISK (`test_claimWithoutDebtRepaymentInflatesETAAndHarvestProfit`)
    ///      If this redemption has an associated predeposit, calling this function WITHOUT
    ///      immediately calling CooldownVault.retrieveDebt() will cause estimatedTotalAssets()
    ///      to DOUBLE-COUNT the value until debt is settled:
    ///      1. Once as CooldownVault shares (from predeposit) in want.balanceOf
    ///      2. Once as claimed underlying assets in externalUnderlyingToken.balanceOf
    ///      This inflates reported total assets and can affect harvest calculations, share pricing,
    ///      and withdrawal accounting. The double-counting persists until retrieveDebt() is called.
    ///
    ///      TL;DR: IF YOU USE THIS, DO NOT HARVEST BEFORE REPAYING ALL OUTSTANDING DEBT TO COOLDOWNVAULT
    function emergencyClaim(uint256 redeemIndex)
        external
        override
        onlyGovernance
        nonReentrant
        returns (bool success, uint256 claimedAmount)
    {
        (success, claimedAmount) = requestClaim(redeemIndex);
        if (success) {
            emit EmergencyClaim(redeemIndex, claimedAmount);
        }
    }

    /// @notice Force clear all redemption tracking state for emergency migration
    /// @dev DANGEROUS: Only use when redemptions are stuck and normal migration is blocked
    ///      This does NOT claim or cancel the actual redemptions in the external vault.
    ///      The new strategy or governance must handle those separately.
    function emergencyClearRedemptions() external onlyGovernance {
        if (activeRedemptionIds.length() == 0) revert NoActiveRedemptions();

        //Set governance as operator to handle pending claims manually
        originVault.setOperator(msg.sender, true);

        uint256 count = activeRedemptionIds.length();

        // Clear all active redemption IDs
        while (activeRedemptionIds.length() > 0) {
            activeRedemptionIds.remove(activeRedemptionIds.at(0));
        }

        // Reset tracking variables
        totalSharesInRedemption = 0;
        totalUnbackedRedemptionShares = 0;

        emit ForceMigrationInitiated(address(0), count);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Returns whether a redemption request has completed its cooldown and is ready to claim
    /// @dev Provides additional visibility to distinguish claimable (fulfilled) redemptions from those already claimed
    function isRedemptionClaimable(uint256 redeemIndex)
        external
        view
        returns (bool isClaimable, uint256 claimableShares)
    {
        RedemptionRequest storage request = redemptionRequests[redeemIndex];
        if (request.shares == 0 || request.isClaimed) {
            return (false, 0);
        }

        claimableShares = _claimableShares(request);
        isClaimable = _isRedemptionClaimable(request, claimableShares);
    }

    function _claimableShares(RedemptionRequest storage request) private view returns (uint256) {
        if (request.shares == 0) return 0;
        return originVault.claimableRedeemRequest(request.vaultRequestId, address(this));
    }

    function _isRedemptionClaimable(
        RedemptionRequest storage request,
        uint256 claimableShares
    )
        private
        view
        returns (bool)
    {
        if (request.shares == 0) return false;
        return claimableShares >= request.shares;
    }

    // ============================================
    // YEARN STRATEGY FUNCTIONS
    // ============================================

    function prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        // Step 1: mark the portfolio before touching cash so Yearn debt/profit math starts from the
        // same share-denominated view that estimatedTotalAssets() already de-duplicates predeposits.
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        _debtPayment = Math.min(_debtOutstanding, totalAssets);
        totalAssets -= _debtPayment;
        totalDebt -= _debtPayment;

        if (totalAssets > totalDebt) {
            _profit = totalAssets - totalDebt;
        }

        (uint256 toReturn,) = liquidatePosition(_profit + _debtPayment);

        // Step 2: re-snapshot after liquidation, because OriginVault may not settle everything and
        // totalDebt can shift when Vault.vy pulls cash, so we align profit/loss with what is actually ready.
        totalAssets = estimatedTotalAssets();
        totalDebt = vault.strategies(address(this)).totalDebt;

        _debtPayment = Math.min(_debtPayment, Math.min(toReturn, totalAssets));
        totalAssets -= _debtPayment;
        totalDebt -= _debtPayment;

        if (totalAssets > totalDebt) {
            _profit = Math.min(toReturn - _debtPayment, totalAssets - totalDebt);
            _loss = 0;
        } else {
            _profit = 0;
            _loss = totalDebt - totalAssets;
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        virtual
        override
        nonReentrant
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        _redepositUnderlyingSurplus();

        uint256 pendingInvested = want.balanceOf(address(this));

        // Calculate target reserve to preserve
        uint256 reserveRatio = reserveRatioBps;
        uint256 targetReserve = reserveRatio > 0 ? Math.mulDiv(estimatedTotalAssets(), reserveRatio, 10_000) : 0;
        uint256 actualReserve = Math.min(pendingInvested, targetReserve);

        // Case 1: Small request - fulfill entirely from reserve
        if (_amountNeeded <= actualReserve) {
            return (_amountNeeded, 0);
        }

        // Reserve surplus beyond target (can use without touching targetReserve)
        uint256 availableWithoutReserve = pendingInvested > actualReserve ? pendingInvested - actualReserve : 0;

        // Case 2: Can fulfill without touching targetReserve
        if (availableWithoutReserve >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // Case 3: Need external withdrawal
        // Request more from external to preserve reserve
        (,, uint256 lossShares) = premintCooldownVault(_amountNeeded - availableWithoutReserve);

        // Use all available want (reserve + newly minted from external)
        // This naturally handles external shortfall by consuming reserve
        uint256 available = want.balanceOf(address(this));
        if (_amountNeeded > available) {
            _liquidatedAmount = available;
            _loss = Math.min(_amountNeeded - available, lossShares);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal virtual override returns (uint256 _amountFreed) {
        _redepositUnderlyingSurplus();
        premintCooldownVault(estimatedTotalAssets());
        uint256 gross = want.balanceOf(address(this));
        _amountFreed = remainingPredepositDebt >= gross ? 0 : gross - remainingPredepositDebt;
    }

    /**
     * @notice Override to mark redemptions as backed by predeposit
     * @dev The predeposit and redemption are created atomically in super.premintCooldownVault(),
     *      so backed redemptions don't need to be counted in estimatedTotalAssets() separately
     *      (their value is already in want.balanceOf via CooldownVault shares).
     */
    function premintCooldownVault(uint256 sharesNeeded)
        internal
        virtual
        override
        returns (uint256 predepositId, uint256 preShares, uint256 lossShares)
    {
        uint256 beforeNextRedeemId = nextRedemptionId;
        (predepositId, preShares, lossShares) = super.premintCooldownVault(sharesNeeded);

        uint256 redeemIndex = 0;
        if (predepositId != 0) {
            redeemIndex = externalRedeemIndexes[predepositId];
        } else {
            revert PremintFailed();
        }

        // If requestRedeem failed, there is nothing to tag.
        if (redeemIndex == 0) return (predepositId, preShares, lossShares);

        if (predepositId != 0 && preShares > 0) {
            isBackedRedemption[redeemIndex] = true;
        } else {
            revert PremintFailed();
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal virtual override nonReentrant {
        if (emergencyExit) return;

        // Redeposit idle underlying while holding back what is needed for predeposit debt
        _redepositUnderlyingSurplus();

        // Re-evaluate after potential deposits
        uint256 pendingInvested = want.balanceOf(address(this));
        if (_debtOutstanding >= pendingInvested) return;

        // Calculate investable amount while preserving target reserve
        uint256 availableShares = pendingInvested - _debtOutstanding;
        uint256 reserveRatio = reserveRatioBps;
        if (reserveRatio > 0) {
            uint256 targetReserve = Math.mulDiv(estimatedTotalAssets(), reserveRatio, 10_000);
            if (availableShares <= targetReserve) return;
            availableShares = availableShares - targetReserve;
        }

        uint256 toInvestShares;
        unchecked {
            uint256 _free = cooldownVault.maxInstantRedeem(address(this));
            toInvestShares = Math.min(_free, availableShares);
        }

        uint256 toInvestAssets = cooldownVault.instantRedeem(toInvestShares);

        // Block investment if accumulated shortfall exceeds tolerance
        // NOTE: if originVault finalizes claims if and only if full amounts are fulfilled (as in the case of
        // OriginVault),
        // then there will be no remainingPredepositDebt; but in general, if claimed amounts are less than expected,
        // then there will be outstanding debt to repay.
        if (remainingPredepositDebt > shortfallTolerance) {
            toInvestAssets = 0;
        }

        // Deposit to external vault, track filled vs unfilled
        (,, uint256 filledAssets) = requestDeposit(toInvestAssets);
        uint256 unfilledAssets = toInvestAssets - filledAssets;

        // Return unfilled assets to CooldownVault for liquidity
        if (unfilledAssets > 0) {
            externalUnderlyingToken.forceApprove(address(cooldownVault), unfilledAssets);
            cooldownVault.deposit(unfilledAssets, address(this));
        }
    }

    function prepareMigration(address _newStrategy) internal virtual override {
        // If redemptions still exist, migration cannot proceed normally
        // Governance must first claim/redemption+repay debts so that _requireNoOutstandingDebt passes
        if (activeRedemptionIds.length() > 0) {
            revert MigrationInProgress();
        }

        // Block migration if there is outstanding predeposit debt to CooldownVault
        _requireNoOutstandingDebt();

        // Transfer all assets
        uint256 externalShareBal = externalShareToken.balanceOf(address(this));
        if (externalShareBal > 0) {
            externalShareToken.safeTransfer(_newStrategy, externalShareBal);
        }

        uint256 externalUnderlyingBal = externalUnderlyingToken.balanceOf(address(this));
        if (externalUnderlyingBal > 0) {
            externalUnderlyingToken.safeTransfer(_newStrategy, externalUnderlyingBal);
        }
    }

    function protectedTokens() internal view virtual override returns (address[] memory) {
        address[] memory protected = new address[](2);
        protected[0] = address(externalShareToken);
        protected[1] = address(externalUnderlyingToken);
        return protected;
    }

    function tendTrigger(uint256 /* callCostInWei */ ) public view virtual override returns (bool) {
        if (emergencyExit) return false;

        uint256 pendingInvested = want.balanceOf(address(this));
        if (pendingInvested == 0) return false;

        uint256 idleBalance = cooldownVault.idleBalance();
        if (idleBalance == 0) return false;

        return beforeExternalDeposit(Math.min(idleBalance, pendingInvested));
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        bool trigger = super.harvestTrigger(callCostInWei);
        uint256 lastReport = getStrategyParams().lastReport;
        if (trigger) {
            if (forceHarvestTriggerOnce) return true;
            if ((block.timestamp - lastReport) >= maxReportDelay) return true;
        } else {
            return false;
        }
        if (block.timestamp == lastReport) return false;

        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = getStrategyParams().totalDebt;
        uint256 credit = vault.creditAvailable();

        uint256 _debtPayment = 0;
        uint256 _debtOutstanding = vault.debtOutstanding();
        if (totalAssets > _debtOutstanding) {
            _debtPayment = _debtOutstanding;
        } else {
            _debtPayment = totalAssets;
        }
        totalAssets -= _debtPayment;
        totalDebt -= _debtPayment;

        uint256 _profit = 0;
        if (totalAssets > totalDebt) {
            _profit = totalAssets - totalDebt;
        }

        uint256 halfCreditThreshold = creditThreshold >> 1;
        uint256 totalAvail = _debtPayment + _profit;
        if (totalAvail < credit) {
            // receive want from vault
            return (credit - totalAvail) >= halfCreditThreshold;
        } else if (totalAvail > credit) {
            // send want to vault
            return (totalAvail - credit) >= halfCreditThreshold;
        }

        return false;
    }

    /**
     * @notice Value the strategy even while redemptions settle asynchronously.
     * @dev Calculation summary:
     * 1) CooldownVault shares held (want.balanceOf) - includes predeposited shares
     * 2) Active OriginVault shares not in redemption (externalShareToken.balanceOf)
     * 3) Underlying assets claimed but not yet redeployed (externalUnderlyingToken.balanceOf)
     * 4) Unbacked redemptions (emergencyRedeem or predeposit returned zero) valued at current exchange rate
     *
     * NOTE: remainingPredepositDebt is subtracted because it represents a shortfall - the amount
     * still owed to CooldownVault when claimed underlying was less than the predeposit amount.
     * Right after predeposit, remainingPredepositDebt is 0 (it only increases when repayment
     * falls short). Without this subtraction, assets would be overstated by the shortfall amount.
     *
     * ASSUMPTIONS:
     * 1. Normal premint flow is treated as fully backed. If predeposit returns 0, the redemption
     *    is recorded as unbacked so claim-time accounting and ETA stay in sync.
     * 2. Unbacked redemptions arise from emergencyRedeem() and from premint flows where predeposit
     *    failed/returned zero.
     * 3. All unbacked redemptions are valued at current rate, not the locked fulfillment rate.
     *    The rate difference is typically small and not worth the added complexity.
     *
     * ⚠️ KNOWN LIMITATION: TEMPORARY DOUBLE-COUNTING DURING EMERGENCY CLAIM
     * If emergencyClaim() is called on a redemption with an associated predeposit,
     * this function will DOUBLE-COUNT the value until CooldownVault.retrieveDebt() is called.
     * Mitigation: Always call retrieveDebt() immediately after emergency claims.
     */
    function estimatedTotalAssets() public view virtual override returns (uint256) {
        // 1) CooldownVault shares held by the strategy (includes predeposited shares which
        //    represent the value of backed redemptions in flight)
        uint256 cooldownShares = want.balanceOf(address(this));

        // 2) Active OriginVault position (shares not in redemption)
        uint256 activeShares = externalShareToken.balanceOf(address(this));
        uint256 investedAssets = originVault.convertToAssets(activeShares);

        // 3) Underlying assets claimed from OriginVault but not yet redeployed
        uint256 pendingAssets = externalUnderlyingToken.balanceOf(address(this));

        // 4) Unbacked redemptions (emergencyRedeem or predeposit returned zero)
        uint256 unbackedRedemptionAssets =
            totalUnbackedRedemptionShares > 0 ? originVault.convertToAssets(totalUnbackedRedemptionShares) : 0;

        uint256 totalUnderlyingAssets = investedAssets + pendingAssets + unbackedRedemptionAssets;

        // Convert underlying exposure to CooldownVault shares and add already-held shares
        uint256 totalAsset = cooldownShares + cooldownVault.previewDeposit(totalUnderlyingAssets);

        // Subtract any shortfall still owed to CooldownVault from underpaid predeposits
        if (remainingPredepositDebt > totalAsset) {
            return 0;
        } else {
            return totalAsset - remainingPredepositDebt;
        }
    }
}
