// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { BaseCooldownStrategy } from "@superearn/core/strategy/BaseCooldownStrategy.sol";
import { CustomVault } from "@superearn/core/strategy/custom/CustomVault.sol";

/**
 * @title CustomYearnStrategy
 * @notice Yearn strategy on Kaia that holds CustomVault shares as its external position
 * @dev Inherits BaseCooldownStrategy where:
 *      - externalShareToken = CustomVault (ERC4626)
 *      - externalUnderlyingToken = USDT (CustomVault's asset)
 *      - want = CooldownVault shares (1:1 with USDT)
 *
 *      Key difference from StrategyOriginVault:
 *      - requestRedeem() only records a debt entry internally (no actual CustomVault.redeem)
 *      - Debt repayment is manual: manager withdraws from CustomVault out-of-band
 *      - repayPredepositDebt() transfers already-prepared USDT (no external claim)
 *      - DP-based reserve check: ensures prior unclaimed debts are reserved before paying later ones
 *      - Shortfall only when CustomVault is effectively depleted AND strategy is insolvent
 */
contract CustomYearnStrategy is BaseCooldownStrategy {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    error InvalidCustomVaultAddress();
    error InvalidCooldownPeriod();
    error InsufficientUSDTForDebtRepayment(uint256 required, uint256 available);

    // ============================================
    // EVENTS
    // ============================================

    error InvalidReserveRatio();
    error EmergencyClaimNotSupported();
    error EmergencyRedeemNotSupported();
    error RequestClaimNotSupported();

    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event DepositedToCustomVault(uint256 assets, uint256 shares);
    event WithdrawnFromCustomVault(uint256 shares, uint256 assets);
    event DebtRecordCreated(uint256 indexed redeemId, uint256 usdtAmount);
    event ReserveRatioUpdated(uint256 oldRatioBps, uint256 newRatioBps);

    // ============================================
    // STRUCTS
    // ============================================

    struct DebtRecord {
        uint256 usdtAmount;
        uint256 sharesCommitted;
        uint256 timestamp;
        bool isClaimed;
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    CustomVault public immutable customVault;

    /// @notice Informational cooldown period returned to CooldownVault during predeposit.
    /// @dev This value is NOT enforced by predepositDebtRetrievable() or repayPredepositDebt().
    ///      Retrievability is determined solely by prepared USDT liquidity (balance-based),
    ///      not by elapsed time. The cooldown is recorded by CooldownVault for off-chain
    ///      coordination (e.g., keeper scheduling) but has no on-chain gating effect.
    uint256 public cooldownPeriod;

    /// @notice Internal debt tracking for premint flow (no actual CustomVault.redeem)
    mapping(uint256 redeemId => DebtRecord) public debtRecords;
    uint256 public nextRedeemId = 1;

    /// @notice Cumulative debt amount up to each redeemId (for DP-based reserve check)
    mapping(uint256 redeemId => uint256) public accDebtAmount;

    /// @notice Total USDT amount repaid across all debts (for DP-based reserve check)
    uint256 public accRepaidDebtAmount;

    /// @notice Dust threshold for shortfall condition ($1 in 6-decimal USDT)
    uint256 public constant DUST_THRESHOLD = 1e6;

    /// @notice Maximum reserve ratio (10% of total assets)
    uint256 public constant MAX_RESERVE_RATIO_BPS = 1000;

    /// @notice Reserve ratio in basis points (0 = no reserve, 100 = 1%)
    uint256 public reserveRatioBps;

    /// @notice CustomVault shares already committed to outstanding DebtRecords.
    /// @dev Tracks shares referenced by requestRedeem() that have not yet been settled
    ///      via repayPredepositDebt(). Prevents premintCooldownVault() from reusing
    ///      the same shares to back multiple pre-mints.
    uint256 public committedExternalShares;

    /// @notice Committed shares that have already been redeemed from CustomVault
    ///         (via withdrawFromCustomVault) but whose DebtRecord has not yet been
    ///         settled via repayPredepositDebt().
    /// @dev Represents the portion of committedExternalShares that has left the
    ///      strategy's CustomVault share balance. Used to compute
    ///      "still-in-balance committed shares" = committedExternalShares - redeemedButUnsettledShares,
    ///      so share-availability checks in premintCooldownVault() and liquidateAllPositions()
    ///      don't double-subtract shares that are no longer in balance.
    ///      Invariant: redeemedButUnsettledShares <= committedExternalShares.
    uint256 public redeemedButUnsettledShares;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize the CustomYearnStrategy
     * @param _vault Address of the Yearn vault (want = CooldownVault shares)
     * @param _customVault Address of the CustomVault (ERC4626, asset = USDT)
     * @param _cooldownPeriod Initial cooldown period in seconds
     */
    constructor(
        address _vault,
        address _customVault,
        uint256 _cooldownPeriod
    )
        BaseCooldownStrategy(_vault, _customVault, CustomVault(_customVault).asset())
    {
        if (_customVault == address(0)) revert InvalidCustomVaultAddress();
        if (_cooldownPeriod == 0) revert InvalidCooldownPeriod();

        customVault = CustomVault(_customVault);
        cooldownPeriod = _cooldownPeriod;

        // ERC4626 standard rounding, no buffer needed
        AMOUNT_TO_SHARE_BUFFER = 0;

        reserveRatioBps = 100; // 1% default reserve

        minReportDelay = 0;
        maxReportDelay = 1 days;
    }

    // ============================================
    // STRATEGY NAME
    // ============================================

    function name() external pure override returns (string memory) {
        return "CustomYearnStrategy";
    }

    // ============================================
    // ABSTRACT FUNCTION IMPLEMENTATIONS
    // ============================================

    /// @notice Returns the informational cooldown period for CooldownVault predeposit flow.
    /// @dev This cooldown is NOT enforced on-chain — debt retrievability and repayment are
    ///      gated purely by USDT liquidity availability, not by elapsed time.
    function getCooldownPeriod() public view virtual override returns (uint256) {
        return cooldownPeriod;
    }

    /**
     * @notice Deposit USDT into CustomVault
     * @param assets Amount of USDT to deposit
     */
    function requestDeposit(uint256 assets)
        internal
        virtual
        override
        returns (bool success, uint256 shares, uint256 filledAssets)
    {
        if (!beforeExternalDeposit(assets)) return (false, 0, 0);

        externalUnderlyingToken.forceApprove(address(customVault), assets);
        try customVault.deposit(assets, address(this)) returns (uint256 sharesReceived) {
            success = true;
            shares = sharesReceived;
            filledAssets = assets;
            emit DepositedToCustomVault(assets, shares);
        } catch {
            externalUnderlyingToken.forceApprove(address(customVault), 0);
            success = false;
        }
    }

    /**
     * @notice Record a debt entry without actual CustomVault redemption
     * @dev Unlike StrategyOriginVault which calls originVault.requestRedeem(),
     *      this only tracks the debt internally. The manager manually withdraws
     *      from CustomVault later.
     *
     *      The returned _cooldownPeriod is informational only — it signals an expected
     *      preparation window to CooldownVault / off-chain keepers but is NOT enforced
     *      on-chain by predepositDebtRetrievable() or repayPredepositDebt().
     * @param shares Number of CustomVault shares representing the debt
     */
    function requestRedeem(uint256 shares)
        internal
        virtual
        override
        returns (bool success, uint256 redeemId, uint256 redeemUnderlyingAmount, uint256 _cooldownPeriod)
    {
        if (!beforeExternalRedeem(shares)) return (false, 0, 0, 0);

        redeemUnderlyingAmount = customVault.previewRedeem(shares);
        redeemId = nextRedeemId++;

        debtRecords[redeemId] = DebtRecord({
            usdtAmount: redeemUnderlyingAmount,
            sharesCommitted: shares,
            timestamp: block.timestamp,
            isClaimed: false
        });

        accDebtAmount[redeemId] = accDebtAmount[redeemId - 1] + redeemUnderlyingAmount;
        committedExternalShares += shares;

        success = true;
        _cooldownPeriod = getCooldownPeriod();

        emit DebtRecordCreated(redeemId, redeemUnderlyingAmount);
    }

    /**
     * @notice Intentionally disabled in CustomYearnStrategy.
     * @dev Settlement is routed exclusively through repayPredepositDebt(), which applies
     *      the DP-based reserve check, updates accRepaidDebtAmount, crystallizes shortfall
     *      when CustomVault is depleted, and releases both committedExternalShares and
     *      redeemedButUnsettledShares. The inherited requestClaim() flow from
     *      BaseCooldownStrategy bypasses all of that accounting — if a future refactor
     *      un-overrode repayPredepositDebt() or emergencyClaim(), calls would silently
     *      corrupt invariants (e.g., double-claim, stale reserve checks, missing
     *      shortfall crystallization). Reverting here forces any such regression to
     *      fail loudly rather than drift.
     */
    function requestClaim(uint256 /* redeemIndex */)
        internal
        virtual
        override
        returns (bool, uint256)
    {
        revert RequestClaimNotSupported();
    }

    /**
     * @notice Override to exclude committed shares from available balance
     * @dev CustomYearnStrategy.requestRedeem() does not actually redeem CustomVault shares —
     *      it only records a debt entry. Without this override, premintCooldownVault() would
     *      treat the same shares as available for multiple pre-mints. This subtracts
     *      committedExternalShares so only uncommitted shares can back new debt.
     */
    function premintCooldownVault(uint256 sharesNeeded)
        internal
        virtual
        override
        returns (uint256 predepositId, uint256 preShares, uint256 lossShares)
    {
        bool redeemSuccess;
        uint256 redeemIndex;
        uint256 redeemUsdt;
        uint256 _cooldownPeriod;
        {
            uint256 _needUsdt = cooldownVault.previewMint(sharesNeeded);
            uint256 _needSusdt = previewWithdraw(_needUsdt + AMOUNT_TO_SHARE_BUFFER);
            uint256 _susdtBalance = externalShareToken.balanceOf(address(this));
            // Exclude only committed shares that are STILL in balance. Shares already
            // redeemed via withdrawFromCustomVault but not yet settled via
            // repayPredepositDebt are naturally absent from _susdtBalance, so subtracting
            // the full committedExternalShares would double-count them.
            uint256 _effectiveCommitted = committedExternalShares > redeemedButUnsettledShares
                ? committedExternalShares - redeemedButUnsettledShares
                : 0;
            uint256 _available = _susdtBalance > _effectiveCommitted
                ? _susdtBalance - _effectiveCommitted
                : 0;
            uint256 shares = Math.min(_needSusdt, _available);

            (redeemSuccess, redeemIndex, redeemUsdt, _cooldownPeriod) = requestRedeem(shares);
            if (!redeemSuccess) return (0, 0, 0);
        }
        if (!emergencyExit && redeemIndex == 0) revert InvalidExternalRedeem();

        if (_cooldownPeriod == 0) {
            externalUnderlyingToken.forceApprove(address(cooldownVault), redeemUsdt);
            preShares = cooldownVault.deposit(redeemUsdt, address(this));
            lossShares = sharesNeeded > preShares ? (sharesNeeded - preShares) : 0;
            return (0, preShares, lossShares);
        }

        (predepositId, preShares) = cooldownVault.predeposit(redeemUsdt);
        if (predepositId == 0) return (0, 0, 0);
        lossShares = sharesNeeded > preShares ? (sharesNeeded - preShares) : 0;

        externalRedeemIndexes[predepositId] = redeemIndex;

        emit Preminted(predepositId, redeemUsdt, preShares, redeemIndex);
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256 shares) {
        return customVault.previewDeposit(assets);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256 assets) {
        return customVault.previewMint(shares);
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256 shares) {
        return customVault.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256 assets) {
        return customVault.previewRedeem(shares);
    }

    function getLastRedeemIndex() internal view virtual override returns (uint256) {
        return nextRedeemId - 1;
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
        DebtRecord storage record = debtRecords[redeemIndex];
        return (redeemIndex, record.timestamp, address(this), record.usdtAmount, record.isClaimed);
    }

    function getSupplyCap() public view virtual override returns (uint256 supplyAssetsCap, uint256 availableAssets) {
        supplyAssetsCap = type(uint256).max;
        availableAssets = type(uint256).max;
    }

    function isPredepositAlreadyClaimed(uint256 predepositId) external view virtual override returns (bool isClaimed) {
        uint256 redeemIndex = externalRedeemIndexes[predepositId];
        if (redeemIndex == 0) return false;
        return debtRecords[redeemIndex].isClaimed;
    }

    /**
     * @notice Check if a predeposit debt can be retrieved (DP-based reserve check)
     * @dev Uses cumulative debt tracking (same pattern as CooldownVault._claim) to allow
     *      out-of-order retrieval while ensuring prior unclaimed debts are reserved for.
     *
     *      NOTE: This function intentionally does NOT enforce the cooldownPeriod as a timing gate.
     *      The cooldown returned by getCooldownPeriod() / requestRedeem() is informational only —
     *      it is recorded by CooldownVault for off-chain keeper scheduling, but retrievability
     *      is determined solely by whether sufficient USDT liquidity has been prepared.
     *      The same applies to the repayment path in repayPredepositDebt().
     * @param predepositId The predeposit ID to check
     * @return isRetrievable True if full repayment is possible, or if CustomVault is depleted
     *         and strategy is insolvent (terminal shortfall — allows bad-debt crystallization)
     */
    function predepositDebtRetrievable(uint256 predepositId)
        external
        view
        virtual
        override
        returns (bool isRetrievable)
    {
        uint256 redeemIndex = externalRedeemIndexes[predepositId];
        if (redeemIndex == 0) return false;

        DebtRecord storage record = debtRecords[redeemIndex];
        if (record.isClaimed) return false;

        // DP-based reserve check (same pattern as CooldownVault._claim):
        // Ensure enough USDT for this debt after reserving for all prior unclaimed debts.
        uint256 _accDebtAmount = accDebtAmount[redeemIndex - 1];
        uint256 reservedForPriorDebts = _accDebtAmount > accRepaidDebtAmount ? _accDebtAmount - accRepaidDebtAmount : 0;

        uint256 usdtBalance = externalUnderlyingToken.balanceOf(address(this));
        uint256 available = usdtBalance > reservedForPriorDebts ? usdtBalance - reservedForPriorDebts : 0;

        if (available >= record.usdtAmount) return true;

        // Allow shortfall settlement when CustomVault is depleted and strategy
        // cannot cover the debt — matches the shortfall branch in repayPredepositDebt().
        uint256 customVaultValue = customVault.totalAssets();
        bool customVaultDepleted =
            customVaultValue <= DUST_THRESHOLD || externalShareToken.balanceOf(address(this)) == 0;
        uint256 wantAsUsdt = cooldownVault.previewRedeem(want.balanceOf(address(this)));
        uint256 totalStrategyHoldings = usdtBalance + wantAsUsdt;

        return customVaultDepleted && totalStrategyHoldings < record.usdtAmount;
    }

    function beforeExternalDeposit(uint256 assets) internal view virtual override returns (bool valid) {
        valid = customVault.previewDeposit(assets) > 0;
    }

    function beforeExternalRedeem(uint256 shares) internal view virtual override returns (bool valid) {
        valid = customVault.previewRedeem(shares) > 0;
    }

    // ============================================
    // REPAY PREDEPOSIT DEBT (OVERRIDE)
    // ============================================

    /**
     * @notice Repay predeposit debt with already-prepared USDT
     * @dev Overrides BaseCooldownStrategy because:
     *      1. No external claim needed — USDT is prepared by manager via withdrawFromCustomVault
     *      2. Custom shortfall logic: revert unless CustomVault is effectively empty
     *      3. DP-based reserve check ensures prior unclaimed debts are reserved for
     *
     *      Shortfall condition: CustomVault effectively depleted (totalAssets <= dust OR
     *      strategy holds no CustomVault shares) AND strategy's total holdings < debt.
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

        uint256 redeemIndex = externalRedeemIndexes[predepositId];
        DebtRecord storage record = debtRecords[redeemIndex];
        if (record.isClaimed) revert ClaimAlreadyProcessed();

        // DP-based reserve check (same pattern as CooldownVault._claim):
        // Before paying this debt, ensure enough USDT remains for all prior unclaimed debts.
        uint256 _accDebtAmount = accDebtAmount[redeemIndex - 1];
        uint256 reservedForPriorDebts = _accDebtAmount > accRepaidDebtAmount ? _accDebtAmount - accRepaidDebtAmount : 0;

        uint256 usdtBalance = externalUnderlyingToken.balanceOf(address(this));
        uint256 available = usdtBalance > reservedForPriorDebts ? usdtBalance - reservedForPriorDebts : 0;

        if (available >= predepositDebt) {
            // Happy path: full repayment
            repayAmount = predepositDebt;
        } else {
            // Check shortfall condition: CustomVault effectively empty + strategy insolvent
            uint256 customVaultValue = customVault.totalAssets();
            // Convert want (CooldownVault shares) to USDT equivalent before aggregating
            // with raw USDT balance to avoid mixing share and asset units.
            uint256 wantAsUsdt = cooldownVault.previewRedeem(want.balanceOf(address(this)));
            uint256 totalStrategyHoldings = usdtBalance + wantAsUsdt;

            bool customVaultDepleted =
                customVaultValue <= DUST_THRESHOLD || externalShareToken.balanceOf(address(this)) == 0;
            if (customVaultDepleted && totalStrategyHoldings < predepositDebt) {
                // Record shortfall — CustomVault is depleted and strategy cannot cover debt
                repayAmount = available;
                remainingPredepositDebt += predepositDebt - available;
            } else {
                // Manager has not yet prepared enough USDT — revert and retry later
                revert InsufficientUSDTForDebtRepayment(predepositDebt, available);
            }
        }

        record.isClaimed = true;
        // Release committed shares now that the debt is settled (or shortfall-crystallized).
        //
        // The settled debt consumes USDT previously produced by withdrawFromCustomVault.
        // Decrementing redeemedButUnsettledShares by record.sharesCommitted (capped at the
        // current redeemedButUnsettledShares so it never underflows) releases the
        // withdrawn-share allocation paired with this debt. The cap
        // `toMark = min(shares, committedExternalShares - redeemedButUnsettledShares)`
        // in withdrawFromCustomVault ensures redeemedButUnsettledShares <= committedExternalShares
        // always holds, so this direct subtract is safe and semantically correct even when
        // settlements occur out of withdraw order (a case where the previous clamp-based
        // release failed to decrement redeemedButUnsettledShares and caused effectiveCommitted
        // to under-represent the still-in-balance committed shares).
        uint256 toRelease = record.sharesCommitted < redeemedButUnsettledShares
            ? record.sharesCommitted
            : redeemedButUnsettledShares;
        redeemedButUnsettledShares -= toRelease;
        committedExternalShares -= record.sharesCommitted;
        // Increment by full original debt amount (not partial repayAmount) to match CooldownVault pattern.
        // Shortfall is already tracked separately in remainingPredepositDebt.
        accRepaidDebtAmount += record.usdtAmount;
        externalUnderlyingToken.safeTransfer(msg.sender, repayAmount);
        emit PredepositDebtRepaid(predepositId, repayAmount);
    }

    // ============================================
    // YEARN STRATEGY FUNCTIONS
    // ============================================

    /**
     * @notice Estimated total assets, adjusted for outstanding predeposit debt
     * @dev Unlike the base implementation, this strategy's requestRedeem() only
     *      records an internal debt entry and does not burn CustomVault shares.
     *      After premintCooldownVault, the strategy simultaneously holds:
     *        (1) externalShareToken (CustomVault shares backing the debt), and
     *        (2) want (CooldownVault shares freshly minted against the debt).
     *      Naively summing both would double-count the same economic value, so
     *      we subtract the USDT amount currently owed to CooldownVault
     *      (strategyDebtOutstanding) from the underlying preview before
     *      aggregation. remainingPredepositDebt is not subtracted again here
     *      because it is already included in strategyDebtOutstanding.
     */
    function estimatedTotalAssets() public view virtual override returns (uint256) {
        uint256 pendingInvested = want.balanceOf(address(this));

        uint256 underlyingToPreview = externalUnderlyingToken.balanceOf(address(this));
        underlyingToPreview += previewRedeem(externalShareToken.balanceOf(address(this)));

        // Exclude USDT obligated to CooldownVault — these funds back `pendingInvested`
        // (the preminted CooldownVault shares) and must not count as free assets.
        // If external position cannot fully cover the debt, propagate the excess into
        // pendingInvested so that loss recognition is not suppressed.
        uint256 outstandingDebt = cooldownVault.strategyDebtOutstanding(address(this));
        if (underlyingToPreview >= outstandingDebt) {
            underlyingToPreview -= outstandingDebt;
        } else {
            uint256 excessDebt = outstandingDebt - underlyingToPreview;
            underlyingToPreview = 0;
            uint256 excessDebtInWant = cooldownVault.previewDeposit(excessDebt);
            pendingInvested = pendingInvested > excessDebtInWant ? pendingInvested - excessDebtInWant : 0;
        }

        uint256 previewInWant = cooldownVault.previewDeposit(underlyingToPreview);
        return pendingInvested + previewInWant;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        virtual
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        _debtPayment = Math.min(_debtOutstanding, totalAssets);
        totalAssets -= _debtPayment;
        totalDebt -= _debtPayment;

        if (totalAssets > totalDebt) {
            _profit = totalAssets - totalDebt;
        }

        (uint256 toReturn,) = liquidatePosition(_profit + _debtPayment);

        // Re-snapshot after liquidation
        totalAssets = estimatedTotalAssets();
        totalDebt = vault.strategies(address(this)).totalDebt;

        _debtPayment = Math.min(_debtPayment, toReturn);
        totalAssets = totalAssets > _debtPayment ? totalAssets - _debtPayment : 0;
        totalDebt = totalDebt > _debtPayment ? totalDebt - _debtPayment : 0;

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

        // Case 1: Small request — fulfill entirely from reserve
        if (_amountNeeded <= actualReserve) {
            return (_amountNeeded, 0);
        }

        // Reserve surplus beyond target (can use without touching targetReserve)
        uint256 availableWithoutReserve = pendingInvested > actualReserve ? pendingInvested - actualReserve : 0;

        // Case 2: Can fulfill without touching targetReserve
        if (availableWithoutReserve >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // Case 3: Need external withdrawal — premint to preserve reserve
        (,, uint256 lossShares) = premintCooldownVault(_amountNeeded - availableWithoutReserve);

        // Use all available want (reserve + newly minted from external)
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

        // Use uncommitted shares directly instead of estimatedTotalAssets() to avoid
        // under-requesting when outstandingDebt > 0 (ETA already deducts debt).
        // Only subtract committed shares that are STILL in balance; shares already
        // redeemed via withdrawFromCustomVault (redeemedButUnsettledShares) are
        // naturally absent from shareBalance and must not be double-counted.
        uint256 shareBalance = externalShareToken.balanceOf(address(this));
        uint256 _effectiveCommitted = committedExternalShares > redeemedButUnsettledShares
            ? committedExternalShares - redeemedButUnsettledShares
            : 0;
        uint256 uncommitted = shareBalance > _effectiveCommitted ? shareBalance - _effectiveCommitted : 0;
        if (uncommitted > 0) {
            uint256 uncommittedWant = cooldownVault.previewDeposit(previewRedeem(uncommitted));
            premintCooldownVault(uncommittedWant);
        }

        uint256 gross = want.balanceOf(address(this));
        _amountFreed = remainingPredepositDebt >= gross ? 0 : gross - remainingPredepositDebt;
    }

    /**
     * @notice Deploy idle CooldownVault shares into CustomVault
     * @dev InstantRedeem CooldownVault shares → USDT → deposit to CustomVault.
     *      Respects reserve ratio and shortfall tolerance.
     */
    function adjustPosition(uint256 _debtOutstanding) internal virtual override nonReentrant {
        if (emergencyExit) return;

        // Block investment if accumulated shortfall exceeds tolerance
        if (remainingPredepositDebt > shortfallTolerance) return;

        // Redeposit USDT surplus to CooldownVault (keeps reserve for debt)
        _redepositUnderlyingSurplus();

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

        // InstantRedeem CooldownVault shares → USDT
        uint256 toInvestShares;
        unchecked {
            uint256 _free = cooldownVault.maxInstantRedeem(address(this));
            toInvestShares = Math.min(_free, availableShares);
        }
        if (toInvestShares == 0) return;

        uint256 toInvestAssets = cooldownVault.instantRedeem(toInvestShares);

        // Deposit USDT to CustomVault, return unfilled to CooldownVault
        (,, uint256 filledAssets) = requestDeposit(toInvestAssets);
        uint256 unfilledAssets = toInvestAssets - filledAssets;

        if (unfilledAssets > 0) {
            externalUnderlyingToken.forceApprove(address(cooldownVault), unfilledAssets);
            cooldownVault.deposit(unfilledAssets, address(this));
        }

        emit AdjustPosition(this.getUtilizationRate(), filledAssets, unfilledAssets, estimatedTotalAssets());
    }

    function prepareMigration(address _newStrategy) internal virtual override {
        // Block migration if there is outstanding predeposit debt to CooldownVault
        _requireNoOutstandingDebt();

        // Atomically hand off CustomVault execution authority so that share custody
        // and deposit/withdraw/redeem permissions stay aligned after migration.
        customVault.migrateCustomYearnStrategy(_newStrategy);

        // Transfer CustomVault shares
        uint256 externalShareBal = externalShareToken.balanceOf(address(this));
        if (externalShareBal > 0) {
            externalShareToken.safeTransfer(_newStrategy, externalShareBal);
        }

        // Transfer idle USDT
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

    function ethToWant(uint256 /* _amtInWei */ ) public view virtual override returns (uint256) {
        return 0;
    }

    // ============================================
    // MANAGER FUNCTIONS
    // ============================================

    /**
     * @notice Withdraw USDT from CustomVault by redeeming shares
     * @dev Used by keeper to prepare USDT for predeposit debt repayment.
     *      This is the manual step that replaces the automatic claim flow.
     *
     *      NOTE: This function intentionally has no guard against committedExternalShares.
     *      Unlike other strategies where committed shares must not be redeemed externally,
     *      CustomYearnStrategy.requestRedeem() only records a debt entry without burning
     *      shares. The keeper MUST call this function to convert committed shares into USDT
     *      before repayPredepositDebt() can settle the debt. estimatedTotalAssets() remains
     *      correct because USDT received substitutes for the burned share value, and
     *      outstandingDebt subtraction prevents double-counting.
     * @param shares Number of CustomVault shares to redeem
     * @return assets Amount of USDT received
     */
    function withdrawFromCustomVault(uint256 shares) external onlyKeepers nonReentrant returns (uint256 assets) {
        assets = customVault.redeem(shares, address(this), address(this));

        // Mark the portion of the withdrawn shares that corresponds to still-unsettled
        // committed debt. Any excess is keeper preparation that does not affect debt
        // accounting and is intentionally NOT recorded, so the invariant
        // redeemedButUnsettledShares <= committedExternalShares always holds.
        uint256 unmarkedCommitted = committedExternalShares > redeemedButUnsettledShares
            ? committedExternalShares - redeemedButUnsettledShares
            : 0;
        uint256 toMark = shares < unmarkedCommitted ? shares : unmarkedCommitted;
        if (toMark > 0) {
            redeemedButUnsettledShares += toMark;
        }

        emit WithdrawnFromCustomVault(shares, assets);
    }

    // ============================================
    // GOVERNANCE FUNCTIONS
    // ============================================

    /**
     * @notice Update the informational cooldown period
     * @dev This cooldown is NOT enforced on-chain. It serves as a hint to CooldownVault
     *      and off-chain keepers for scheduling USDT preparation. Retrievability and
     *      repayment are gated by liquidity availability, not elapsed time.
     * @param _newCooldownPeriod New cooldown period in seconds
     */
    function setCooldownPeriod(uint256 _newCooldownPeriod) external onlyGovernance {
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

    // ============================================
    // OVERRIDES
    // ============================================

    /// @notice Emergency redeem is not supported — requestRedeem() only creates debt records
    ///         without withdrawing from CustomVault, which would leave unresolvable phantom debt.
    function emergencyRedeem(uint256)
        external
        virtual
        override
        onlyGovernance
        returns (bool, uint256, uint256, uint256)
    {
        revert EmergencyRedeemNotSupported();
    }

    /// @notice Emergency claim is not supported — debt repayment is manual via withdrawFromCustomVault
    function emergencyClaim(uint256) external virtual override onlyGovernance returns (bool, uint256) {
        revert EmergencyClaimNotSupported();
    }
}
