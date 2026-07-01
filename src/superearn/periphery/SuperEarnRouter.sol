// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { MulticallUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import { MathUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "@superearn/interface/IRegistry.sol";
import { IVault } from "@superearn/interface/IVault.sol";
import { ICooldownVault } from "@superearn/interface/ICooldownVault.sol";
import { ISuperEarnRouter } from "@superearn/interface/ISuperEarnRouter.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title SuperEarnRouter
 * @notice Helper contract for depositing into Yearn vaults with CooldownVault
 * @dev Handles the flow: underlying -> CooldownVault -> yVault
 */
contract SuperEarnRouter is Initializable, ISuperEarnRouter, MulticallUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // === Custom Errors ===
    error InsufficientShares(uint256 shortfall);
    error InvalidReceiver();
    error InsufficientAssets(uint256 shortfall);
    error InvalidPrice();
    error Unauthorized();
    error VaultNotWhitelisted(address vault);
    error DepositBlocked(address yVault);
    error DepositWindowClosed(address yVault, uint64 deadline);
    error RedeemBlocked(address yVault);
    error RedeemWindowClosed(address yVault, uint64 deadline);
    error DepositorNotWhitelisted(address yVault, address depositor);
    error RedeemDebtLimitExceeded(address yVault, uint256 totalDebt, uint256 limit);

    // === Events ===
    event DepositorWhitelistEnforcementSet(address indexed yVault, bool enforced);
    event DepositorWhitelisted(address indexed yVault, address indexed depositor, bool allowed);
    event RedeemTotalDebtLimitSet(address indexed yVault, uint256 limit);

    // === State Variables ===

    /// @notice Address of the Yearn Registry contract
    address public registry;
    address public remoteVault;
    /// @notice Mapping of whitelisted yVault addresses
    mapping(address => bool) public whitelistedVaults;
    /// @notice Per-yVault lockup configuration controlling deposit/redeem gating
    mapping(address yVault => ISuperEarnRouter.VaultLockup) public vaultLockups;

    /// @notice Per-yVault flag: when true, only addresses in `yVaultDepositorWhitelist` may deposit
    ///         to that vault via the router. Default: false (no per-depositor gating).
    mapping(address yVault => bool) public depositorWhitelistEnforced;
    /// @notice Per-yVault depositor whitelist. Only consulted when
    ///         `depositorWhitelistEnforced[yVault]` is true.
    mapping(address yVault => mapping(address depositor => bool)) public yVaultDepositorWhitelist;

    /// @notice Per-yVault cap on the linked CooldownVault's `totalDebt`, enforced at the END of a
    ///         redeem. A redeem reverts when the CooldownVault's `totalDebt` exceeds this value after
    ///         the redemption request has been created. Denominated in the CooldownVault's underlying
    ///         asset units (e.g. 6-decimal USDC/USDT). 0 = no cap (check disabled; default).
    mapping(address yVault => uint256 maxTotalDebt) public maxRedeemTotalDebt;

    // === Initializer ===

    /**
     * @notice Initializes the router with a registry address
     * @param _registry Address of the Yearn Registry contract
     */
    function initialize(address _registry, address _owner) public initializer {
        __Multicall_init();
        __Ownable_init();
        registry = _registry;
        _transferOwnership(_owner);
    }

    // ============================================
    // DEPOSIT FUNCTIONS
    // ============================================

    /**
     * @notice Deposits underlying tokens into a Yearn vault through CooldownVault
     * @dev Flow: underlying -> CooldownVault -> yVault. Deposits to msg.sender.
     * @param yVault Address of the Yearn vault to deposit into
     * @param amount Amount of underlying tokens to deposit
     * @param minSharesOut Minimum amount of yVault shares expected (slippage protection)
     * @return Amount of yVault shares received
     */
    function deposit(address yVault, uint256 amount, uint256 minSharesOut) external returns (uint256) {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        return _deposit(yVault, amount, sender, minSharesOut);
    }

    /**
     * @notice Deposits underlying tokens into a Yearn vault for a specific recipient
     * @dev Flow: underlying -> CooldownVault -> yVault
     * @param yVault Address of the Yearn vault to deposit into
     * @param amount Amount of underlying tokens to deposit
     * @param receiver Address to receive the yVault shares
     * @param minSharesOut Minimum amount of yVault shares expected (slippage protection)
     * @return Amount of yVault shares received
     */
    function deposit(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut
    )
        external
        returns (uint256)
    {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        return _deposit(yVault, amount, receiver, minSharesOut);
    }

    /**
     * @notice Deposits underlying tokens into a Yearn vault using EIP-2612 permit
     * @dev Avoids separate approval transaction by using permit
     * @param yVault Address of the Yearn vault to deposit into
     * @param amount Amount of underlying tokens to deposit
     * @param receiver Address to receive the yVault shares
     * @param minSharesOut Minimum amount of yVault shares expected (slippage protection)
     * @param deadline Deadline timestamp for the permit
     * @param v v component of the signature
     * @param r r component of the signature
     * @param s s component of the signature
     * @return Amount of yVault shares received
     */
    function depositWithPermit(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256)
    {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        // Get CooldownVault from yVault
        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());
        // Get underlying asset
        IERC20 underlyingAsset = IERC20(cooldownVault.asset());

        // Use permit for gasless approval
        IERC20Permit(address(underlyingAsset)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        return _deposit(yVault, amount, receiver, minSharesOut);
    }

    /**
     * @notice Deposits underlying tokens into a Yearn vault with referral tracking
     * @dev Flow: underlying -> CooldownVault -> yVault
     * @param yVault Address of the Yearn vault to deposit into
     * @param amount Amount of underlying tokens to deposit
     * @param minSharesOut Minimum amount of yVault shares expected (slippage protection)
     * @param referralCode Referral code for tracking
     * @return Amount of yVault shares received
     */
    function depositWithReferral(
        address yVault,
        uint256 amount,
        uint256 minSharesOut,
        bytes32 referralCode
    )
        external
        returns (uint256)
    {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        return _depositWithReferral(yVault, amount, sender, minSharesOut, referralCode);
    }

    /**
     * @notice Deposits underlying tokens into a Yearn vault using EIP-2612 permit with referral tracking
     * @dev Avoids separate approval transaction by using permit
     * @param yVault Address of the Yearn vault to deposit into
     * @param amount Amount of underlying tokens to deposit
     * @param receiver Address to receive the yVault shares
     * @param minSharesOut Minimum amount of yVault shares expected (slippage protection)
     * @param referralCode Referral code for tracking
     * @param deadline Deadline timestamp for the permit
     * @param v v component of the signature
     * @param r r component of the signature
     * @param s s component of the signature
     * @return Amount of yVault shares received
     */
    function depositWithPermitAndReferral(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut,
        bytes32 referralCode,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256)
    {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        // Get CooldownVault from yVault
        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());
        // Get underlying asset
        IERC20 underlyingAsset = IERC20(cooldownVault.asset());

        // Use permit for gasless approval
        IERC20Permit(address(underlyingAsset)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        return _depositWithReferral(yVault, amount, receiver, minSharesOut, referralCode);
    }

    /**
     * @notice Internal function to handle deposits
     * @dev Performs the actual deposit logic with reentrancy protection
     * @param yVault Address of the Yearn vault
     * @param amount Amount of underlying tokens
     * @param receiver Recipient of yVault shares
     * @param minSharesOut Minimum shares expected
     * @return yShares Amount of yVault shares minted
     */
    function _deposit(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut
    )
        internal
        returns (uint256 yShares)
    {
        if (amount == 0) return 0;
        if (!whitelistedVaults[yVault]) revert VaultNotWhitelisted(yVault);
        _checkDepositAllowed(yVault);
        _checkDepositorAllowed(yVault, msg.sender);

        // Get CooldownVault from yVault
        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());

        // Get underlying asset
        IERC20 underlyingAsset = IERC20(cooldownVault.asset());

        // 1. Transfer underlying from user
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);

        // 2. Deposit to CooldownVault and get shares
        underlyingAsset.forceApprove(address(cooldownVault), amount);
        uint256 cooldownShares = cooldownVault.deposit(amount, address(this));

        // 3. Deposit CooldownVault shares to yVault
        IERC20(address(cooldownVault)).forceApprove(yVault, cooldownShares);
        yShares = IVault(yVault).deposit(cooldownShares, receiver);

        // Slippage protection
        if (yShares < minSharesOut) revert InsufficientShares(minSharesOut - yShares);

        emit Deposited(msg.sender, receiver, yVault, amount, yShares);
    }

    /**
     * @notice Internal function to handle deposits with referral
     * @dev Performs the actual deposit logic with referral event
     * @param yVault Address of the Yearn vault
     * @param amount Amount of underlying tokens
     * @param receiver Recipient of yVault shares
     * @param minSharesOut Minimum shares expected
     * @param referralCode Referral code for tracking
     * @return yShares Amount of yVault shares minted
     */
    function _depositWithReferral(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut,
        bytes32 referralCode
    )
        internal
        returns (uint256 yShares)
    {
        if (amount == 0) return 0;
        if (!whitelistedVaults[yVault]) revert VaultNotWhitelisted(yVault);
        _checkDepositAllowed(yVault);
        _checkDepositorAllowed(yVault, msg.sender);

        // Get CooldownVault from yVault
        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());

        // Get underlying asset
        IERC20 underlyingAsset = IERC20(cooldownVault.asset());

        // 1. Transfer underlying from user
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);

        // 2. Deposit to CooldownVault and get shares
        underlyingAsset.forceApprove(address(cooldownVault), amount);
        uint256 cooldownShares = cooldownVault.deposit(amount, address(this));

        // 3. Deposit CooldownVault shares to yVault
        IERC20(address(cooldownVault)).forceApprove(yVault, cooldownShares);
        yShares = IVault(yVault).deposit(cooldownShares, receiver);

        // Slippage protection
        if (yShares < minSharesOut) revert InsufficientShares(minSharesOut - yShares);

        emit Deposited(msg.sender, receiver, yVault, amount, yShares);
        emit DepositedWithReferral(msg.sender, receiver, yVault, amount, yShares, referralCode);
    }

    /**
     * @notice Reverts if deposit is blocked or the deposit window has closed for this vault
     * @param yVault Address of the Yearn vault
     */
    function _checkDepositAllowed(address yVault) internal view {
        ISuperEarnRouter.VaultLockup memory lockup = vaultLockups[yVault];
        if (lockup.depositBlocked) revert DepositBlocked(yVault);
        if (lockup.depositDeadline != 0 && block.timestamp > lockup.depositDeadline) {
            revert DepositWindowClosed(yVault, lockup.depositDeadline);
        }
    }

    /**
     * @notice Reverts if redeem is blocked or the redeem window has closed for this vault
     * @param yVault Address of the Yearn vault
     */
    function _checkRedeemAllowed(address yVault) internal view {
        ISuperEarnRouter.VaultLockup memory lockup = vaultLockups[yVault];
        if (lockup.redeemBlocked) revert RedeemBlocked(yVault);
        if (lockup.redeemDeadline != 0 && block.timestamp > lockup.redeemDeadline) {
            revert RedeemWindowClosed(yVault, lockup.redeemDeadline);
        }
    }

    // ============================================
    // REDEEM FUNCTIONS
    // ============================================

    /**
     * @notice Internal function to handle redemptions
     * @dev Performs the actual redemption logic
     * @param yVault Address of the Yearn vault
     * @param yShares Amount of yVault shares to redeem
     * @param receiver Address to receive the underlying assets after cooldown
     * @param minAssetsOut Minimum amount of underlying assets expected
     * @return requestId ID of the cooldown redemption request
     */
    function _redeem(
        address yVault,
        uint256 yShares,
        address receiver,
        uint256 minAssetsOut
    )
        internal
        returns (uint256 requestId)
    {
        if (yShares == 0) return 0;
        if (!whitelistedVaults[yVault]) revert VaultNotWhitelisted(yVault);
        _checkRedeemAllowed(yVault);

        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());
        IERC20(yVault).safeTransferFrom(msg.sender, address(this), yShares);

        uint256 filledShares;
        uint256 cooldownShares;
        {
            filledShares = IERC20(yVault).balanceOf(address(this));
            cooldownShares = cooldownVault.balanceOf(address(this));
            IVault(yVault).withdraw(yShares, address(this), 10_000); // support unfilled withdrawal
            filledShares = filledShares - IERC20(yVault).balanceOf(address(this));
            cooldownShares = cooldownVault.balanceOf(address(this)) - cooldownShares;
        }

        // Create redemption request in CooldownVault
        requestId = cooldownVault.redeem(cooldownShares, receiver, address(this));
        uint256 assets;
        uint256 cooldownPeriod;
        {
            address actualReceiver;
            (actualReceiver, assets,, cooldownPeriod,) = cooldownVault.redeemRequests(requestId);
            // Just a sanity check
            if (actualReceiver != receiver) revert InvalidReceiver();
        }

        {
            uint256 filledMinAssetsOut = MathUpgradeable.mulDiv(minAssetsOut, filledShares, yShares);
            if (assets < filledMinAssetsOut) revert InsufficientAssets(filledMinAssetsOut - assets);
        }

        // Return remaining shares
        uint256 remainingShares = IERC20(yVault).balanceOf(address(this));
        if (remainingShares > 0) {
            IERC20(yVault).safeTransfer(msg.sender, remainingShares);
        }

        // Cap the CooldownVault's outstanding redemption debt. The redeem above (via the Yearn
        // withdraw → strategy liquidation → predeposit path) may have grown the CooldownVault's
        // `totalDebt`; if a per-yVault limit is configured and the resulting `totalDebt` exceeds it,
        // revert so a single redeem cannot push promised-future-asset debt past a safe threshold.
        // A 0 limit means the cap is disabled (default), leaving existing vaults unaffected.
        uint256 debtLimit = maxRedeemTotalDebt[yVault];
        if (debtLimit != 0) {
            uint256 currentTotalDebt = cooldownVault.totalDebt();
            if (currentTotalDebt > debtLimit) {
                revert RedeemDebtLimitExceeded(yVault, currentTotalDebt, debtLimit);
            }
        }

        emit Redeemed(msg.sender, receiver, yVault, yShares, filledShares, requestId, assets);
    }

    /**
     * @notice Redeem yVault shares for underlying assets with cooldown period
     * @dev Flow: yVault shares -> CooldownVault shares -> redemption request (cooldown). Redeems to msg.sender.
     * @param yVault Address of the Yearn vault
     * @param yShares Amount of yVault shares to redeem
     * @param minAssetsOut Minimum amount of underlying assets expected (slippage protection)
     * @return requestId ID of the cooldown redemption request
     */
    function redeem(address yVault, uint256 yShares, uint256 minAssetsOut) external returns (uint256 requestId) {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        return _redeem(yVault, yShares, sender, minAssetsOut);
    }

    /**
     * @notice Redeem yVault shares for underlying assets for a specific recipient
     * @dev Flow: yVault shares -> CooldownVault shares -> redemption request (cooldown)
     * @param yVault Address of the Yearn vault
     * @param yShares Amount of yVault shares to redeem
     * @param receiver Address to receive the underlying assets after cooldown
     * @param minAssetsOut Minimum amount of underlying assets expected (slippage protection)
     * @return requestId ID of the cooldown redemption request
     */
    function redeem(
        address yVault,
        uint256 yShares,
        address receiver,
        uint256 minAssetsOut
    )
        external
        returns (uint256 requestId)
    {
        address sender = msg.sender;
        if (remoteVault != address(0) && sender != remoteVault) {
            revert Unauthorized();
        }

        return _redeem(yVault, yShares, receiver, minAssetsOut);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Gets the latest endorsed vault for a specific token
     * @param token Address of the token (CooldownVault)
     * @return Address of the latest endorsed vault for that token
     */
    function endorsedVault(address token) external view returns (address) {
        return IRegistry(registry).latestVault(token);
    }

    /**
     * @notice Preview the amount of yVault shares received for an asset deposit
     * @dev Mirrors Vault.vy's _issueSharesForAmount logic exactly:
     *      shares = amount * totalSupply / _freeFunds()
     *      where _freeFunds() = _totalAssets() - _calculateLockedProfit()
     * @param yVault Address of the Yearn vault
     * @param amount Amount of underlying assets to deposit
     * @return expectedShares Estimated yVault shares minted
     */
    function previewDeposit(address yVault, uint256 amount) external view returns (uint256 expectedShares) {
        if (amount == 0) return 0;

        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());
        uint256 cooldownShares = cooldownVault.convertToShares(amount);

        uint256 vaultTotalSupply = IVault(yVault).totalSupply();
        if (vaultTotalSupply == 0) {
            // No existing shares, mint 1:1 (same as Vault.vy line 864)
            return cooldownShares;
        }

        uint256 freeFunds = _calculateFreeFunds(yVault);
        if (freeFunds == 0) revert InvalidPrice();

        // Exact same formula as Vault.vy line 861: shares = amount * totalSupply / _freeFunds()
        expectedShares = cooldownShares * vaultTotalSupply / freeFunds;
    }

    function previewMint(address yVault, uint256 yShares) external view returns (uint256 underlyingAssets) {
        if (yShares == 0) return 0;

        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());

        uint256 supply = IVault(yVault).totalSupply();
        uint256 cooldownSharesNeeded;
        if (supply == 0) {
            cooldownSharesNeeded = yShares; // 1:1
        } else {
            uint256 freeFunds = _calculateFreeFunds(yVault);
            if (freeFunds == 0) revert InvalidPrice();
            cooldownSharesNeeded = MathUpgradeable.mulDiv(yShares, freeFunds, supply, MathUpgradeable.Rounding.Up);
        }

        // ERC4626 inverse quote: shares -> assets (rounding up)
        underlyingAssets = cooldownVault.previewMint(cooldownSharesNeeded);
    }

    /**
     * @notice Calculate free funds available in the vault (mirrors Vault.vy's _freeFunds, line 846-847)
     * @dev _freeFunds() = _totalAssets() - _calculateLockedProfit()
     * @param yVault Address of the Yearn vault
     * @return Free funds available
     */
    function _calculateFreeFunds(address yVault) internal view returns (uint256) {
        // _totalAssets() = totalIdle + totalDebt (Vault.vy line 813)
        uint256 totalAssets = IVault(yVault).totalIdle() + IVault(yVault).totalDebt();
        uint256 calculatedLockedProfit = _calculateLockedProfit(yVault);
        return totalAssets - calculatedLockedProfit;
    }

    /**
     * @notice Calculate locked profit (mirrors Vault.vy's _calculateLockedProfit, line 831-842)
     * @dev lockedFundsRatio = (block.timestamp - lastReport) * lockedProfitDegradation
     *      if lockedFundsRatio < DEGRADATION_COEFFICIENT:
     *          return lockedProfit - (lockedFundsRatio * lockedProfit / DEGRADATION_COEFFICIENT)
     *      else:
     *          return 0
     * @param yVault Address of the Yearn vault
     * @return Calculated locked profit
     */
    function _calculateLockedProfit(address yVault) internal view returns (uint256) {
        uint256 lockedFundsRatio =
            (block.timestamp - IVault(yVault).lastReport()) * IVault(yVault).lockedProfitDegradation();

        uint256 DEGRADATION_COEFFICIENT = 1e18;

        if (lockedFundsRatio < DEGRADATION_COEFFICIENT) {
            uint256 lockedProfit = IVault(yVault).lockedProfit();
            // Vault.vy line 836-839
            return lockedProfit - (lockedFundsRatio * lockedProfit / DEGRADATION_COEFFICIENT);
        } else {
            return 0;
        }
    }

    /**
     * @notice Preview the amount of underlying assets that would be received from redeeming yVault shares
     * @dev Calculates: yShares -> cooldownShares -> underlying assets
     * @param yVault Address of the Yearn vault
     * @param yShares Amount of yVault shares to redeem
     * @return Amount of underlying assets that would be received
     */
    function previewRedeem(address yVault, uint256 yShares) external view returns (uint256) {
        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());

        // Calculate how many cooldownShares we would get from withdrawing yShares
        // yVault.pricePerShare() gives the value per share scaled by 10 ** decimals
        uint256 cooldownShares = (yShares * IVault(yVault).pricePerShare()) / (10 ** IVault(yVault).decimals());

        return cooldownVault.previewRedeem(cooldownShares);
    }

    /**
     * @notice Preview the amount of yVault shares needed to withdraw a specific amount of assets
     * @dev Calculates: assets -> cooldownShares (via previewWithdraw) -> yShares
     *      Rounds UP to ensure we request enough shares to cover the requested assets
     * @param yVault Address of the Yearn vault
     * @param assets Amount of underlying assets to withdraw
     * @return ySharesNeeded Amount of yVault shares needed
     */
    function previewWithdraw(address yVault, uint256 assets) external view returns (uint256 ySharesNeeded) {
        if (assets == 0) return 0;

        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());

        // Step 1: Calculate CooldownVault shares needed for the asset amount
        uint256 cooldownSharesNeeded = cooldownVault.previewWithdraw(assets);

        // Step 2: Convert CooldownVault shares to yVault shares (round UP to ensure sufficient shares)
        uint256 decimals = IVault(yVault).decimals();
        uint256 pricePerShare = IVault(yVault).pricePerShare();
        if (pricePerShare == 0) revert InvalidPrice();

        ySharesNeeded =
            MathUpgradeable.mulDiv(cooldownSharesNeeded, 10 ** decimals, pricePerShare, MathUpgradeable.Rounding.Up);
    }

    /**
     * @notice Maximum yVault shares that can be redeemed through this router in a single redeem()
     *         without tripping the per-yVault CooldownVault `totalDebt` cap (`maxRedeemTotalDebt`).
     * @dev Returns the largest `yShares` for which a redeem() is expected to satisfy the
     *      end-of-redeem check `cooldownVault.totalDebt() <= maxRedeemTotalDebt[yVault]`.
     *
     *      Model: redeeming `yShares` withdraws
     *          cooldownShares = yShares * pricePerShare / 10**decimals
     *      worth of CooldownVault shares. In the worst case the strategy must `predeposit()` that
     *      entire amount, growing `totalDebt` by up to that many underlying assets (the CooldownVault
     *      keeps a 1:1 share:asset ratio). The remaining room under the cap is
     *      `headroom = limit - currentTotalDebt`, so the bound is:
     *          maxShares = floor( convertToShares(headroom) * 10**decimals / pricePerShare )
     *
     *      The conversions round DOWN (floor) on purpose: the result UNDER-estimates the redeemable
     *      shares so that passing the returned value straight into redeem() keeps `totalDebt` at or
     *      below the cap and does NOT revert with `RedeemDebtLimitExceeded`.
     *
     *      Special cases:
     *        - limit == 0 (cap disabled)   -> type(uint256).max (this check imposes no restriction)
     *        - currentTotalDebt >= limit   -> 0 (no room left under the cap)
     *
     *      ⚠️ OFF-CHAIN USAGE: this is a point-in-time snapshot computed from the CURRENT
     *      `pricePerShare` and `totalDebt`. A yVault's `pricePerShare` generally rises block-by-block
     *      as strategies accrue/harvest yield, and `totalDebt` can also move between the moment you
     *      read this value and the moment your redeem() actually lands. A higher `pricePerShare` maps
     *      the SAME yShares to MORE CooldownVault shares (hence more debt), so using the returned
     *      amount too tightly can still make redeem() revert. Off-chain consumers MUST leave a safety
     *      buffer (e.g. use ~95-99% of the returned value, or re-quote immediately before submitting)
     *      rather than redeeming the exact amount. Note this view also ignores the deposit/redeem
     *      lockups and whitelist gating — those are enforced separately inside redeem().
     * @param yVault Address of the Yearn vault
     * @return maxShares Maximum yVault shares redeemable under the totalDebt cap (floored)
     */
    function maxRedeemableShares(address yVault) external view returns (uint256 maxShares) {
        uint256 limit = maxRedeemTotalDebt[yVault];
        // 0 means the cap is disabled, so this check imposes no upper bound.
        if (limit == 0) return type(uint256).max;

        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());
        uint256 currentTotalDebt = cooldownVault.totalDebt();
        // Already at or above the cap: no further redeem is allowed.
        if (currentTotalDebt >= limit) return 0;

        uint256 headroom = limit - currentTotalDebt;

        uint256 pricePerShare = IVault(yVault).pricePerShare();
        if (pricePerShare == 0) revert InvalidPrice();
        uint256 decimals = IVault(yVault).decimals();

        // headroom (underlying assets) -> CooldownVault shares (round DOWN), then -> yVault shares
        // (round DOWN). Both floors keep the implied debt at/below `headroom`.
        uint256 maxCooldownShares = cooldownVault.convertToShares(headroom);
        maxShares =
            MathUpgradeable.mulDiv(maxCooldownShares, 10 ** decimals, pricePerShare, MathUpgradeable.Rounding.Down);
    }

    function setRemoteVault(address _remoteVault) external onlyOwner {
        remoteVault = _remoteVault;
        emit RemoteVaultSet(_remoteVault);
    }

    /**
     * @notice Add a yVault address to the whitelist
     * @param yVault Address of the yVault to whitelist
     */
    function addWhitelistedVault(address yVault) external onlyOwner {
        whitelistedVaults[yVault] = true;
        emit VaultWhitelisted(yVault, true);
    }

    /**
     * @notice Remove a yVault address from the whitelist
     * @param yVault Address of the yVault to remove from whitelist
     */
    function removeWhitelistedVault(address yVault) external onlyOwner {
        whitelistedVaults[yVault] = false;
        emit VaultWhitelisted(yVault, false);
    }

    /**
     * @notice Toggle the per-yVault depositor whitelist enforcement.
     * @dev When `enforced` is true, all subsequent deposit() / depositWithReferral() /
     *      depositWithPermit() / depositWithPermitAndReferral() calls targeting this
     *      `yVault` are restricted to addresses set in `yVaultDepositorWhitelist`.
     *      When false (default), no per-depositor check is performed.
     * @param yVault Address of the Yearn vault
     * @param enforced True to enforce the depositor whitelist for this vault
     */
    function setDepositorWhitelistEnforced(address yVault, bool enforced) external onlyOwner {
        depositorWhitelistEnforced[yVault] = enforced;
        emit DepositorWhitelistEnforcementSet(yVault, enforced);
    }

    /**
     * @notice Add or remove a single depositor from the per-yVault depositor whitelist.
     * @dev Has no effect on deposits while `depositorWhitelistEnforced[yVault]` is false.
     * @param yVault Address of the Yearn vault
     * @param depositor Address whose deposit-permission is being changed
     * @param allowed True to allow, false to revoke
     */
    function setDepositorWhitelisted(address yVault, address depositor, bool allowed) external onlyOwner {
        yVaultDepositorWhitelist[yVault][depositor] = allowed;
        emit DepositorWhitelisted(yVault, depositor, allowed);
    }

    /**
     * @notice Batch update of the per-yVault depositor whitelist.
     * @dev All `depositors` are set to the same `allowed` flag in a single call.
     * @param yVault Address of the Yearn vault
     * @param depositors Addresses to add or remove
     * @param allowed True to allow, false to revoke
     */
    function setDepositorsWhitelisted(address yVault, address[] calldata depositors, bool allowed) external onlyOwner {
        uint256 len = depositors.length;
        for (uint256 i = 0; i < len;) {
            yVaultDepositorWhitelist[yVault][depositors[i]] = allowed;
            emit DepositorWhitelisted(yVault, depositors[i], allowed);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Internal depositor gate: reverts when `yVault` enforces the depositor whitelist
     *         and `depositor` is not on it. No-op when enforcement is off.
     */
    function _checkDepositorAllowed(address yVault, address depositor) internal view {
        if (!depositorWhitelistEnforced[yVault]) return;
        if (!yVaultDepositorWhitelist[yVault][depositor]) {
            revert DepositorNotWhitelisted(yVault, depositor);
        }
    }

    /**
     * @notice Configure deposit lockup for a yVault
     * @dev Both fields are written atomically. deadline == 0 disables the time-window check.
     * @param yVault Address of the Yearn vault
     * @param blocked True to hard-block all deposits via the router
     * @param deadline Unix timestamp after which deposits are blocked (0 = no time restriction)
     */
    function setDepositLockup(address yVault, bool blocked, uint64 deadline) external onlyOwner {
        vaultLockups[yVault].depositBlocked = blocked;
        vaultLockups[yVault].depositDeadline = deadline;
        emit DepositLockupSet(yVault, blocked, deadline);
    }

    /**
     * @notice Configure redeem lockup for a yVault
     * @dev Both fields are written atomically. deadline == 0 disables the time-window check.
     * @param yVault Address of the Yearn vault
     * @param blocked True to hard-block all redeems via the router
     * @param deadline Unix timestamp after which redeems are blocked (0 = no time restriction)
     */
    function setRedeemLockup(address yVault, bool blocked, uint64 deadline) external onlyOwner {
        vaultLockups[yVault].redeemBlocked = blocked;
        vaultLockups[yVault].redeemDeadline = deadline;
        emit RedeemLockupSet(yVault, blocked, deadline);
    }

    /**
     * @notice Configure the maximum CooldownVault `totalDebt` permitted at the end of a redeem
     *         for a given yVault.
     * @dev When set to a non-zero value, any redeem() through the router that leaves the linked
     *      CooldownVault's `totalDebt` above `limit` reverts with `RedeemDebtLimitExceeded`. Set to 0
     *      to disable the cap (default). `limit` is denominated in the CooldownVault's underlying
     *      asset units (e.g. 6-decimal USDC/USDT).
     * @param yVault Address of the Yearn vault
     * @param limit Maximum allowed CooldownVault.totalDebt after a redeem (0 = no cap)
     */
    function setMaxRedeemTotalDebt(address yVault, uint256 limit) external onlyOwner {
        maxRedeemTotalDebt[yVault] = limit;
        emit RedeemTotalDebtLimitSet(yVault, limit);
    }

    /**
     * @notice Preview the claimability and maximum assets for a redemption request
     * @dev Returns whether the cooldown period has passed and the maximum claimable amount
     *      considering the vault's current asset balance
     * @param yVault Address of the Yearn vault
     * @param requestId ID of the redemption request from CooldownVault
     * @return isClaimable True if the cooldown period has passed and not yet claimed
     * @return maxAssetsOut Maximum amount of underlying assets that can be claimed
     */
    function previewClaim(
        address yVault,
        uint256 requestId
    )
        external
        view
        returns (bool isClaimable, uint256 maxAssetsOut)
    {
        ICooldownVault cooldownVault = ICooldownVault(IVault(yVault).token());
        (, uint256 assets, uint256 cooldownRequestedTime, uint256 cooldownPeriod, bool claimed) =
            cooldownVault.redeemRequests(requestId);
        isClaimable = (block.timestamp >= cooldownRequestedTime + cooldownPeriod) && !claimed;

        uint256 _managedAssets = cooldownVault.assetBalance();
        maxAssetsOut = MathUpgradeable.min(assets, _managedAssets);
    }

    /**
     * @dev Reserved storage gap so future versions can append variables without
     * shifting inherited storage. See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Own storage: 7 slots, in declaration order (each appended in a later version and
     * never reordered, so every deployed slot is fixed):
     *   registry, remoteVault, whitelistedVaults, vaultLockups,
     *   depositorWhitelistEnforced, yVaultDepositorWhitelist, maxRedeemTotalDebt
     *
     * Block = 7 vars + 43 gap = 50 slots (standard convention). SuperEarnRouter is the
     * most-derived (leaf) contract, so the gap is pure trailing reserve: normalizing it to
     * 43 only shrinks the empty tail and moves NO live data — the 7 variables keep their
     * slots (151..157) and nothing inherits after this gap. (This is safe ONLY because it
     * is a leaf; never resize the gap of an inherited/base contract on a deployed proxy.)
     *
     * To add a variable: append it after maxRedeemTotalDebt and decrement the gap
     * (-> `uint256[42]`). Never reorder/insert/remove an existing variable.
     * See CLAUDE.md "Storage Gap (`__gap`) Convention".
     */
    uint256[43] private __gap;
}
