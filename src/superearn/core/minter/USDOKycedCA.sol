// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { MathUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import { IUSDOExpressV2, IUSDO } from "@superearn/api/USDOExpressV2API.sol";
import { IUSDOKycedCA } from "@superearn/interface/IUSDOKycedCA.sol";
import { IHealthCheck } from "@superearn/interface/IHealthCheck.sol";
import { IERC6900ExecutionHookLightModule } from "@superearn/interface/IERC6900ExecutionHookLightModule.sol";

/**
 * @title USDOKycedCA
 * @notice KYC'd Contract Account for USDOExpress mint/redeem operations
 * @dev Deployed behind TransparentUpgradeableProxy (not UUPS).
 *      USDO is a rebasing token without transferShares. Dust is unavoidable.
 *      USDOExpressV2 uses FIFO queue: success→USDC to `to`, failure→USDO refund to caller.
 */
contract USDOKycedCA is
    Initializable,
    ContextUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IUSDOKycedCA
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ============ Errors ============
    error OnlyGovernance();
    error OnlyPendingGovernance();
    error OnlyStrategy();
    error InvalidAddress();
    error StrategyAlreadyAdded();
    error StrategyNotFound();
    error ChangeNotSubmitted();
    error QueueVerificationFailed(uint256 queueIndex, bytes32 expectedHashId);
    error InvalidHealthCheck();
    error HealthCheckFailed(
        uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding, uint256 totalDebt
    );
    error CoreTokenNotAllowed();
    error PartialDepositNotAllowed();
    error BelowMinimumDeposit(uint256 provided, uint256 minimum);
    error FailedToRedeem(address strategy, uint256 usdoAmt);
    error BelowMinimumRedeem(uint256 provided, uint256 minimum);
    error FailedToClaim(string reason);
    error InvalidDecimalsOffset();
    error InvalidHooks();
    error CooldownPeriodTooLong();

    // ============ Constants ============
    uint256 private constant MAX_COOLDOWN_PERIOD = 365 days;
    /// @dev Base points for fee calculations (matches USDOExpressV2._BASIS_POINTS_BASE)
    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant BUFFER_WEI = 10;
    uint256 private constant DECIMALS_OFFSET_SCALE = 1e12;
    /// @dev Base for USDO share/token conversion (matches USDO._BASE)
    uint256 private constant USDO_DECIMALS_SCALE = 1e18;

    /// @dev Hook entity IDs (ERC-6900 style)
    uint32 private constant ENTITY_DEPOSIT = 1;
    uint32 private constant ENTITY_REDEEM = 2;
    uint32 private constant ENTITY_CLAIM = 3;

    // ============ State Variables ============
    address public governance;
    address public pendingGovernance;

    IUSDOExpressV2 public usdoExpress;
    /// @notice Underlying stablecoin for USDOExpressV2
    /// @dev OpenEden's USDOExpressV2 uses USDC as underlying by default.
    ///      However, on Kaia chain, USDT is used instead while keeping the variable name "usdc".
    ///      We follow this naming convention for consistency with USDOExpressV2.
    IERC20 public usdc;
    IERC20 public usdo;

    EnumerableSet.AddressSet private _strategiesSet;
    EnumerableSet.UintSet private _unclaimedRedeemRequestIds;

    // ============ Redeem Request Storage ============
    mapping(uint256 => RedeemRequest) public redeemRequests;
    /// @notice Cumulative sum of all redeem request previewed USDC amounts up to and including requestId
    mapping(uint256 => uint256) public accRedeemRequestedPreviewedAmt;
    uint256 public lastRedeemRequestId;
    /// @notice Minimum waiting period before claiming. Default: 1 days.
    /// @dev Even after cooldown elapses, claims may fail if USDOExpress hasn't processed the redemption yet.
    ///      Independent of USDOExpress processing time (typically 1-2 business days).
    uint256 public cooldownPeriod;

    // Health Check
    bool public doHealthCheck;
    IHealthCheck public healthCheck;

    /// @notice Total USDO token amount pending in unclaimed redeem requests
    uint256 public totalRedeemedUsdoAmt;
    /// @notice Cumulative sum of previewed USDC amounts from successfully claimed redeem requests
    uint256 public accClaimedPreviewedAmt;
    /// @dev Lowest redeem amount ever requested. Used for dust detection in _calcUsdoRedeemedToUsdc.
    uint256 internal _historicalMinRedeemAmt;

    /// @notice Hooks contract for execution callbacks (ERC-6900 style)
    address public hooks;

    // ============ Modifiers ============
    modifier onlyGovernance() {
        if (_msgSender() != governance) revert OnlyGovernance();
        _;
    }

    modifier onlyStrategy() {
        if (!_strategiesSet.contains(_msgSender())) revert OnlyStrategy();
        _;
    }

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    function initialize(address _usdoExpress, address _governance) external initializer {
        __Context_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_usdoExpress == address(0) || _governance == address(0)) {
            revert InvalidAddress();
        }

        usdoExpress = IUSDOExpressV2(_usdoExpress);
        usdc = IERC20(usdoExpress._usdc());
        usdo = IERC20(address(usdoExpress._usdo()));

        governance = _governance;

        cooldownPeriod = 1 days;

        uint256 usdoDecimals = 10 ** IERC20Metadata(address(usdo)).decimals();
        uint256 usdcDecimals = 10 ** IERC20Metadata(address(usdc)).decimals();
        if (usdoDecimals / usdcDecimals != DECIMALS_OFFSET_SCALE) revert InvalidDecimalsOffset();
        // USDO uses _BASE = 1e18 for share/token conversion (must match USDO_DECIMALS_SCALE)
        if (usdoDecimals != USDO_DECIMALS_SCALE) revert InvalidDecimalsOffset();

        // accRedeemRequestedPreviewedAmt[0] = 0; // explicit initialization
    }

    // ============ USDOExpress Interaction ============

    /**
     * @notice Internal mint function - converts USDC to USDO
     * @dev Assumes USDC is already in this contract
     * @param usdcAmount Amount of USDC to deposit
     * @return usdoMinted Amount of USDO minted
     * @return usdcSpent Actual amount of USDC used (for calculating remaining)
     * @return usdoSharesMinted Number of USDO shares minted
     */
    function _mint(uint256 usdcAmount)
        internal
        returns (uint256 usdoMinted, uint256 usdcSpent, uint256 usdoSharesMinted)
    {
        IUSDO usdoToken = IUSDO(address(usdo));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 usdoBefore = usdo.balanceOf(address(this));
        uint256 sharesBefore = usdoToken.sharesOf(address(this));

        usdc.forceApprove(address(usdoExpress), usdcAmount);
        usdoExpress.instantMint(address(usdc), address(this), usdcAmount);

        usdoMinted = usdo.balanceOf(address(this)) - usdoBefore;
        usdcSpent = usdcBefore - usdc.balanceOf(address(this));
        usdoSharesMinted = usdoToken.sharesOf(address(this)) - sharesBefore;
    }

    /**
     * @notice Internal queue-based redemption with try-catch
     * @dev USDO must already be in this contract. USDC will be received by this contract when operator processes the
     * queue. Uses try-catch to handle potential revert from usdoExpress.redeemRequest.
     * @param usdoAmount Amount of USDO to redeem
     * @return success Whether the redeem succeeded
     * @return usdcAmtPreviewed Previewed USDC amount to be received (0 if failed)
     * @return queueHashId Hash ID of the queue entry in USDOExpress (bytes32(0) if failed)
     */
    function _tryRedeemQueued(uint256 usdoAmount)
        internal
        returns (bool success, uint256 usdcAmtPreviewed, bytes32 queueHashId)
    {
        // Get preview before redeem
        (, usdcAmtPreviewed,) = usdoExpress.previewRedeem(usdoAmount, false);

        // Calculate queue index (current queue length = new request's index, calculated before pushBack)
        uint256 queueIndex = usdoExpress.getRedemptionQueueLength();

        // Calculate queue Hash ID (same method as USDOExpressV2)
        // from = address(this), to = address(this) (USDOKycedCA calls itself as receiver)
        queueHashId = keccak256(abi.encode(address(this), address(this), usdoAmount, block.timestamp, queueIndex));

        // Add to redemption queue - receiver is this contract
        try usdoExpress.redeemRequest(address(this), usdoAmount) {
            // Verification: check that the calculated queueHashId matches the id stored in the actual queue
            (,,, bytes32 actualId) = usdoExpress.getRedemptionQueueInfo(queueIndex);
            if (actualId != queueHashId) revert QueueVerificationFailed(queueIndex, queueHashId);
            success = true;
        } catch {
            success = false;
            usdcAmtPreviewed = 0;
            queueHashId = bytes32(0);
        }
    }

    /// @return queuedUsdoAmt Total USDO amount pending in redemption queue
    function _getQueuedRedemption() internal view returns (uint256 queuedUsdoAmt) {
        queuedUsdoAmt = usdoExpress.getRedemptionUserInfo(address(this));
    }

    /// @dev _mintMinimum = 1e18. Returns minimum in USDO decimals (18).
    function _getMintMinimum() internal view returns (uint256 mintMin) {
        mintMin = usdoExpress._mintMinimum();
        if (mintMin < BUFFER_WEI) mintMin = BUFFER_WEI * DECIMALS_OFFSET_SCALE;
    }

    /// @dev _redeemMinimum = 1e18. Returns minimum in USDO decimals (18).
    function _getRedeemMinimum() internal view returns (uint256 redeemMin) {
        redeemMin = usdoExpress._redeemMinimum();
        if (redeemMin < BUFFER_WEI) redeemMin = BUFFER_WEI * DECIMALS_OFFSET_SCALE;
    }

    /**
     * @notice Calculate amount that redeems exactly all shares without dust
     * @dev dustFreeAmount = ceil(shares * bonusMultiplier / 1e18)
     *      Can be > balanceOf by at most 1 wei, but burn succeeds because
     *      USDO checks convertToShares(amount) <= accountShares, not amount <= balanceOf
     *      Guarantee: usdoDustFreeAmt >= usdoBalanceAmt (always, diff 0~1 wei)
     * @return usdoDustFreeAmt Amount that converts to exactly all shares
     * @return usdoBalanceAmt Current balanceOf (fallback amount)
     */
    function _calcAllUsdoAsDustFree() internal view returns (uint256 usdoDustFreeAmt, uint256 usdoBalanceAmt) {
        IUSDO usdoToken = IUSDO(address(usdo));
        uint256 shares = usdoToken.sharesOf(address(this));
        uint256 multiplier = usdoToken.bonusMultiplier(); // always >= 1e18

        // ceil(shares * multiplier / 1e18)
        usdoDustFreeAmt = MathUpgradeable.mulDiv(shares, multiplier, USDO_DECIMALS_SCALE, MathUpgradeable.Rounding.Up);
        usdoBalanceAmt = usdo.balanceOf(address(this));
    }

    // ============ Core Functions ============

    /**
     * @notice Deposit USDC and receive USDO
     * @param usdcAmt Amount of USDC to deposit
     * @param receiver Address to receive the minted USDO
     * @return usdoAmt Amount of USDO minted
     */
    function deposit(
        uint256 usdcAmt,
        address receiver
    )
        public
        onlyStrategy
        nonReentrant
        whenNotPaused
        returns (uint256 usdoAmt)
    {
        _tryRedeemAllUsdo(type(uint256).max);

        address sender = _msgSender();

        // Pre-execution hook
        bytes memory hookContext;
        address _hooks = hooks;
        if (_hooks != address(0)) {
            hookContext = IERC6900ExecutionHookLightModule(_hooks).preExecutionHook(
                ENTITY_DEPOSIT,
                sender,
                0, // value: not used for ERC20 operations
                abi.encode(usdcAmt, receiver)
            );
        }

        // Check if the deposit amount is greater than the minimum mint amount
        uint256 usdcMinimum = minDeposit();
        if (usdcAmt < usdcMinimum) {
            revert BelowMinimumDeposit(usdcAmt, usdcMinimum);
        }

        // Transfer USDC from sender to this contract
        usdc.safeTransferFrom(sender, address(this), usdcAmt);

        // Mint USDO
        uint256 usdcSpent;
        uint256 usdoSharesMinted;
        (usdoAmt, usdcSpent, usdoSharesMinted) = _mint(usdcAmt);
        // NOTE: Defensive check - USDOExpress confirmed partial deposits do not occur in practice
        if (usdcSpent < usdcAmt) {
            revert PartialDepositNotAllowed();
        }

        // Transfer minted USDO to receiver (dust-free when possible)
        bool dustFreeSuccess;
        if (usdoSharesMinted == IUSDO(address(usdo)).sharesOf(address(this))) {
            // All shares are from this mint → can use dustFreeAmt
            (uint256 dustFreeAmt,) = _calcAllUsdoAsDustFree();
            try IERC20(address(usdo)).transfer(receiver, dustFreeAmt) returns (bool success) {
                dustFreeSuccess = success;
            } catch { }
        }
        // NOTE: Dust-free transfer is only possible when using the entire balance (no pre-existing USDO).
        // (1) cases where USDO already exists in this contract, and
        // (2) fallback if dust-free transfer fails for any reason.
        if (!dustFreeSuccess) {
            usdo.safeTransfer(receiver, usdoAmt);
        }

        // Post-execution hook
        if (_hooks != address(0)) {
            IERC6900ExecutionHookLightModule(_hooks).postExecutionHook(ENTITY_DEPOSIT, hookContext);
        }

        emit Deposited(sender, usdcSpent, usdoAmt);
    }

    /**
     * @notice Redeem USDO for USDC
     * @dev Queued redemption. Allowance-based if owner != msg.sender.
     *      USDO rebasing may cause filledUsdoAmt < usdoAmt. Query via redeemRequests(requestId).
     * @param usdoAmt Amount of USDO to redeem
     * @param owner Address that owns the USDO
     * @return requestId The ID of the created redeem request
     */
    function redeem(
        uint256 usdoAmt,
        address owner
    )
        external
        onlyStrategy
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (usdo.balanceOf(address(this)) >= _historicalMinRedeemAmt) {
            _tryRedeemAllUsdo(type(uint256).max);
        }

        address sender = _msgSender();

        // Pre-execution hook
        bytes memory hookContext;
        address _hooks = hooks;
        if (_hooks != address(0)) {
            hookContext = IERC6900ExecutionHookLightModule(_hooks).preExecutionHook(
                ENTITY_REDEEM,
                sender,
                0, // value: not used for ERC20 operations
                abi.encode(usdoAmt, owner)
            );
        }

        // Check if the redeem amount is greater than the minimum redeem amount
        uint256 usdoMinimum = _getRedeemMinimum(); // always >= 10e12
        if (usdoAmt < usdoMinimum) {
            revert BelowMinimumRedeem(usdoAmt, usdoMinimum);
        }

        // Transfer USDO from owner to this contract
        usdo.safeTransferFrom(owner, address(this), usdoAmt);

        // Submit to USDOExpress redemption queue
        // After transfer: usdoBalance >= usdoAmt >= usdoMinimum, so _tryRedeemAllUsdo always executes.
        (uint256 prorataUsdcPreviewed, uint256 totalFilledUsdoAmt, bytes32 queueHashId) = _tryRedeemAllUsdo(usdoAmt);
        if (queueHashId == bytes32(0)) {
            revert FailedToRedeem(sender, usdoAmt);
        }
        uint256 filledUsdoAmt = totalFilledUsdoAmt < usdoAmt ? totalFilledUsdoAmt : usdoAmt;
        totalRedeemedUsdoAmt += filledUsdoAmt;

        // Track lowest redeem amount for dust detection (use 1 instead of 0 to prevent reset attack)
        if (_historicalMinRedeemAmt == 0 || filledUsdoAmt < _historicalMinRedeemAmt) {
            uint256 buffer = BUFFER_WEI * DECIMALS_OFFSET_SCALE;
            _historicalMinRedeemAmt = filledUsdoAmt > buffer ? filledUsdoAmt - buffer : 1;
        }

        // Create redeem request record
        requestId = ++lastRedeemRequestId;
        accRedeemRequestedPreviewedAmt[requestId] = accRedeemRequestedPreviewedAmt[requestId - 1] + prorataUsdcPreviewed;
        redeemRequests[requestId] = RedeemRequest({
            strategy: sender,
            usdoAmt: filledUsdoAmt,
            usdcPreviewed: prorataUsdcPreviewed,
            usdcReceived: 0,
            cooldownRequestedTime: block.timestamp,
            cooldownPeriod: cooldownPeriod,
            claimed: false
        });
        _unclaimedRedeemRequestIds.add(requestId);

        // Post-execution hook
        if (_hooks != address(0)) {
            IERC6900ExecutionHookLightModule(_hooks).postExecutionHook(ENTITY_REDEEM, hookContext);
        }

        emit RedeemRequested(requestId, sender, filledUsdoAmt, prorataUsdcPreviewed, queueHashId);
    }

    /**
     * @notice Claim USDC from a completed redeem request
     * @dev Only the strategy that created the request can claim
     * SECURITY: nonReentrant is CRITICAL due to intentional CEI violation below. DO NOT REMOVE.
     * @param redeemRequestId The ID of the redeem request to claim
     */
    function claim(uint256 redeemRequestId) external nonReentrant whenNotPaused {
        // ============ PREPARATION (intentional CEI violation) ============
        // Must run BEFORE checks to ensure accurate accounting.
        // Canceled USDO must be re-queued to minimize remainingUsdoAmt,
        // otherwise _calcUsdoRedeemedToUsdc() and _isInOrderClaim() calculations may be skewed.
        // Note: Dust < _historicalMinRedeemAmt is auto-handled (treated as 0).
        // Edge case: _historicalMinRedeemAmt <= remaining < _redeemMinimum (if minRedeemAmount was raised).
        _tryRedeemAllUsdo(type(uint256).max);

        address sender = _msgSender();
        RedeemRequest storage request = redeemRequests[redeemRequestId];

        // Pre-execution hook
        bytes memory hookContext;
        address _hooks = hooks;
        if (_hooks != address(0)) {
            hookContext = IERC6900ExecutionHookLightModule(_hooks).preExecutionHook(
                ENTITY_CLAIM,
                sender,
                0, // value: not used for ERC20 operations
                abi.encode(redeemRequestId)
            );
        }

        // ============ CHECKS ============
        // CHK1. Validate caller authorization
        if (sender != request.strategy && (sender != governance || _strategiesSet.contains(request.strategy))) {
            revert FailedToClaim("UNAUTHORIZED");
        }

        // CHK2. Validate _isClaimable
        (string memory reason, uint256 usdcToTransfer) = _isClaimable(redeemRequestId);
        if (bytes(reason).length > 0) revert FailedToClaim(reason);

        // CHK3. Health check validation
        // Health check only runs when healthCheck contract is configured (intentional).
        if (doHealthCheck && address(healthCheck) != address(0)) {
            _checkHealth(request.usdcPreviewed, usdcToTransfer, totalRedeemedUsdcAmt());
        } else {
            // Auto-restore to true (governance can disable for onetime skip only)
            doHealthCheck = true;
            emit SetDoHealthCheck(true);
        }

        // ============ EFFECTS ============
        request.claimed = true;
        request.usdcReceived = usdcToTransfer;
        accClaimedPreviewedAmt += request.usdcPreviewed;
        totalRedeemedUsdoAmt -= request.usdoAmt;
        _unclaimedRedeemRequestIds.remove(redeemRequestId);

        // ============ INTERACTIONS ============
        usdc.safeTransfer(sender, usdcToTransfer);

        // Post-execution hook
        if (_hooks != address(0)) {
            IERC6900ExecutionHookLightModule(_hooks).postExecutionHook(ENTITY_CLAIM, hookContext);
        }

        emit Claimed(sender, redeemRequestId, request.usdoAmt, usdcToTransfer);
    }

    /**
     * @notice Validate redemption health by comparing expected vs actual USDC received
     * @dev Calculates profit/loss and delegates to healthCheck contract
     * @param _debtAssets Expected USDC (from preview at redeem time)
     * @param _debtPayment Actual USDC to receive
     * @param _totalDebt Total pending redemption value for context
     */
    function _checkHealth(uint256 _debtAssets, uint256 _debtPayment, uint256 _totalDebt) internal view {
        uint256 profit;
        uint256 loss;

        if (_debtPayment > _debtAssets) {
            // profit branch is unreachable
            profit = _debtPayment - _debtAssets;
            // loss = 0;
        } else {
            // profit = 0;
            loss = _debtAssets - _debtPayment;
        }

        if (!healthCheck.check(profit, loss, _debtPayment, 0, _totalDebt)) {
            revert HealthCheckFailed(profit, loss, _debtPayment, 0, _totalDebt);
        }
    }

    /**
     * @dev Redeems entire USDO balance (canceled refunds, donations, rebased yield).
     *      Strategy: (1) try dustFreeAmt, (2) fallback to balanceOf, (3) emit failure if both fail.
     * @param targetUsdoAmt USDO amount for pro-rata preview calculation (type(uint256).max for full)
     * @return prorataUsdcPreviewed Previewed USDC for targetUsdoAmt portion (pro-rata calculated)
     * @return filledUsdoAmt Actual USDO queued (may be < requested due to rebasing)
     * @return queueHashId Queue entry hash ID
     */
    function _tryRedeemAllUsdo(uint256 targetUsdoAmt)
        internal
        returns (uint256 prorataUsdcPreviewed, uint256 filledUsdoAmt, bytes32 queueHashId)
    {
        (uint256 dustFreeAmt, uint256 allUsdoAmt) = _calcAllUsdoAsDustFree();
        uint256 usdoMinimum = _getRedeemMinimum();
        targetUsdoAmt = dustFreeAmt < targetUsdoAmt ? dustFreeAmt : targetUsdoAmt;

        // Can't redeem
        if (allUsdoAmt < usdoMinimum) {
            return (0, 0, bytes32(0));
        }

        uint256 beforeQueuedUsdoAmt = _getQueuedRedemption();

        // Step 1: Try dust-free amount first
        bool success;
        uint256 allUsdcAmtPreviewed;
        (success, allUsdcAmtPreviewed, queueHashId) = _tryRedeemQueued(dustFreeAmt);

        // Step 2: Fallback to balanceOf if dust-free failed
        if (!success) {
            (success, allUsdcAmtPreviewed, queueHashId) = _tryRedeemQueued(allUsdoAmt);
        }
        // After Step 2: Both attempts failed
        if (!success) {
            emit RedeemQueuedAllFailed(dustFreeAmt, allUsdoAmt);
            return (0, 0, bytes32(0));
        }

        // dustFreeAmt >= allUsdoAmt >= filledUsdoAmt
        filledUsdoAmt = _getQueuedRedemption() - beforeQueuedUsdoAmt;

        // Step 3: Calculate proportional preview for targetUsdoAmt
        if (targetUsdoAmt > 0) {
            prorataUsdcPreviewed = targetUsdoAmt < filledUsdoAmt
                ? MathUpgradeable.mulDiv(allUsdcAmtPreviewed, targetUsdoAmt, filledUsdoAmt)
                : allUsdcAmtPreviewed;
            (, uint256 _maxUsdcAmtPreviewed,) = usdoExpress.previewRedeem(targetUsdoAmt, false);
            prorataUsdcPreviewed =
                _maxUsdcAmtPreviewed < prorataUsdcPreviewed ? _maxUsdcAmtPreviewed : prorataUsdcPreviewed;
        }

        emit RedeemQueued(filledUsdoAmt, allUsdcAmtPreviewed, queueHashId);
    }

    /**
     * @notice Convert USDO to claimable USDC using pro-rata distribution
     * @dev Actual USDC received can be less than usdcPreviewed due to fee rate changes:
     *      usdcPreviewed calculated → redemption queued → fee rate increases → redemption processed with new fee.
     *      Therefore, we calculate the appropriate claimable amount using share-based pro-rata distribution.
     *      WARNING: Do NOT use this result directly as claim amount.
     *      Actual claim amount should be min(this result, usdcPreviewed)
     */
    function _calcUsdoRedeemedToUsdc(uint256 usdoAmt) internal view returns (uint256 usdcAmt) {
        uint256 redeemedUsdoAmt = 0; // explicit initialization
        uint256 queuedUsdoAmt = _getQueuedRedemption(); // USDO in USDOExpress queue (pending)

        // remainingUsdoAmt includes three categories (Canceled USDO typically dominates):
        // 1. Canceled USDO (legitimate refunds) → re-submitted to redemption queue
        // 2. Excess USDO (from donations or unexpected inflows)
        // 3. Rebased USDO (accrued yield from rebase mechanism)
        uint256 remainingUsdoAmt = usdo.balanceOf(address(this));
        // Dust detection: amount smaller than any redeem request is guaranteed to be dust
        if (remainingUsdoAmt < _historicalMinRedeemAmt) {
            remainingUsdoAmt = 0;
        }

        uint256 pendingUsdoAmt = queuedUsdoAmt + remainingUsdoAmt; // Total unprocessed USDO

        // Note: redeemedUsdoAmt is approximate since remainingUsdoAmt may include
        // donations or rebased USDO, making redeemedUsdoAmt slightly understated.
        // This improves the USDO→USDC exchange rate for claimers.
        // However, donation attacks are unprofitable: _tryRedeemAllUsdo (called on mint/redeem/claim)
        // re-queues excess USDO, so the extra portion becomes USDC on next successful redemption,
        // ensuring claimers receive at least their entitled amount.
        if (pendingUsdoAmt < totalRedeemedUsdoAmt) {
            redeemedUsdoAmt = totalRedeemedUsdoAmt - pendingUsdoAmt; // Difference = successfully converted to USDC
        }

        if (redeemedUsdoAmt < usdoAmt) {
            // Redemption incomplete: redeemedUsdoAmt may increase later along with USDC balance.
            // Return 0 to invalidate this calculation until redemption catches up.
            return 0;
        }

        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 expected = MathUpgradeable.mulDiv(usdcBalance, usdoAmt, redeemedUsdoAmt);
        return expected < usdcBalance ? expected : usdcBalance;
    }

    /**
     * @notice Calculate the eligible claim amount for a redeem request
     * @dev Returns min(realisticAmt, usdcPreviewed) when redemption is processed,
     *      or usdcPreviewed when redemption is still pending (realisticAmt == 0).
     *      - realisticAmt == 0: Redemption not yet processed, use previewed amount for validation
     *      - realisticAmt < usdcPreviewed: Fee increase after preview, cap at actual receivable
     *      - realisticAmt >= usdcPreviewed: Cap at previewed amount (no windfall gains)
     * @param requestId The ID of the redeem request
     * @return eligibleClaimAmt The claimable USDC amount (capped at usdcPreviewed)
     */
    function _calcEligibleClaimAmt(uint256 requestId) internal view returns (uint256 eligibleClaimAmt) {
        RedeemRequest memory request = redeemRequests[requestId];
        eligibleClaimAmt = request.usdcPreviewed;

        uint256 realisticAmt = _calcUsdoRedeemedToUsdc(request.usdoAmt);
        if (realisticAmt > 0 && realisticAmt < eligibleClaimAmt) {
            eligibleClaimAmt = realisticAmt;
        }
    }

    /**
     * @dev NOT strict FIFO - out-of-order claims allowed if reserves are sufficient.
     *      Ensures claiming this request won't deprive prior requests of their usdcPreviewed.
     *      Calculation:
     *      - reservedForPrior: sum of usdcPreviewed for all prior unclaimed requests
     *      - eligibleClaimAmt: claimable amount (may be < usdcPreviewed if fee increased)
     * @return True if USDC balance sufficient to cover both prior obligations and this claim
     */
    function _isInOrderClaim(uint256 redeemRequestId) internal view returns (bool) {
        uint256 _accRedeemRequestedPreviewedAmt = accRedeemRequestedPreviewedAmt[redeemRequestId - 1];
        // Reserve guarantee: ensure prior unclaimed requests can receive their usdcPreviewed amounts
        // Note: This allows out-of-order claims as long as reserves are sufficient
        uint256 reservedForPrior = _accRedeemRequestedPreviewedAmt > accClaimedPreviewedAmt
            ? _accRedeemRequestedPreviewedAmt - accClaimedPreviewedAmt
            : 0;
        // Eligible claim amount for this request (may be slightly less than usdcPreviewed due to pro-rata)
        uint256 eligibleClaimAmt = _calcEligibleClaimAmt(redeemRequestId);

        // Final check: sufficient balance to cover both prior reserved amounts and this claim
        return usdc.balanceOf(address(this)) >= reservedForPrior + eligibleClaimAmt;
    }

    /// @dev Returns ("", claimableAmt) on success, (reason, 0) on failure.
    function _isClaimable(uint256 redeemRequestId)
        internal
        view
        returns (string memory reason, uint256 claimableUsdcAmt)
    {
        RedeemRequest memory request = redeemRequests[redeemRequestId];

        // CHK1. Validate request exists
        if (request.strategy == address(0)) return ("NOT_FOUND", 0);

        // CHK2. Validate not already claimed
        if (request.claimed) return ("INVALID", 0);

        // CHK3. Validate cooldown period elapsed
        if (block.timestamp < request.cooldownRequestedTime + request.cooldownPeriod) return ("SHOULD_WAIT", 0);

        // CHK4. Validate sufficient USDC balance
        // [Edge Case] Most dust is auto-handled (< _historicalMinRedeemAmt → treated as 0).
        //   Remaining edge case: donation in [_historicalMinRedeemAmt, _redeemMinimum) + fee increase.
        //   This is negligible: attacker loses donation, and next deposit/redeem clears it.
        //   - If usdcBalance < usdcPreviewed due to fee increase → "NO_ASSETS"
        //   - Early claimers may receive full usdcPreviewed; later claimers bear the loss
        //   - INTENTIONAL: whitelisted strategies agreed to this mechanism
        // [Why Unlikely] USDOExpress (contractual partner) has not adjusted fees unilaterally.
        // [Recovery] Transfer >= _redeemMinimum USDO → re-queues all remaining → pro-rata works.
        claimableUsdcAmt = _calcEligibleClaimAmt(redeemRequestId);
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (claimableUsdcAmt > usdcBalance) return ("NO_ASSETS", 0);

        // CHK5. Validate in-order claim
        if (!_isInOrderClaim(redeemRequestId)) return ("OUT_OF_ORDER", 0);

        // reason = ""; means success
    }

    // ============ Preview Functions ============
    //
    // ERC4626 Compliance & BUFFER_WEI Rationale:
    // USDOExpressV2 is NOT ERC4626-compliant (rebasing tokens, non-standard preview).
    // BUFFER_WEI ensures ERC4626 invariants: actual >= preview (deposit/redeem), actual <= preview (mint/withdraw).
    // This ensures callers always receive at least what was previewed.

    function previewDeposit(uint256 usdcAmt) public view returns (uint256 usdoAmt) {
        (,, usdoAmt,) = usdoExpress.previewMint(address(usdc), usdcAmt);
        uint256 _BUFFER_WEI = BUFFER_WEI * DECIMALS_OFFSET_SCALE;
        usdoAmt = usdoAmt > _BUFFER_WEI ? (usdoAmt - _BUFFER_WEI) : 0;
    }

    /// @dev Inverse of previewDeposit. WARNING: Approximation.
    function previewMint(uint256 usdoAmt) public view returns (uint256 usdcAmt) {
        // Reverse bonusMultiplier (ceiling)
        (uint256 curr, uint256 next) = usdoExpress.getBonusMultiplier();
        uint256 usdoBeforeBonus = MathUpgradeable.mulDiv(usdoAmt, next, curr, MathUpgradeable.Rounding.Up);

        // Convert USDO to USDC (ceiling)
        uint256 usdcBase = usdoExpress.convertToUnderlying(address(usdc), usdoBeforeBonus);
        if (usdoBeforeBonus % 1e12 != 0) {
            usdcBase += 1;
        }

        // Reverse fee deduction (ceiling)
        uint256 mintFeeRate = usdoExpress._mintFeeRate();
        if (mintFeeRate >= BASIS_POINTS) {
            return type(uint256).max;
        }
        usdcAmt =
            MathUpgradeable.mulDiv(usdcBase, BASIS_POINTS, BASIS_POINTS - mintFeeRate, MathUpgradeable.Rounding.Up);
        usdcAmt += BUFFER_WEI;
    }

    function previewRedeem(uint256 usdoAmt) public view returns (uint256 usdcAmt) {
        (, usdcAmt,) = usdoExpress.previewRedeem(usdoAmt, false);
        usdcAmt = usdcAmt > BUFFER_WEI ? (usdcAmt - BUFFER_WEI) : 0;
    }

    /// @dev Inverse of previewRedeem (no bonusMultiplier). WARNING: Approximation.
    function previewWithdraw(uint256 usdcAmt) public view returns (uint256 usdoAmt) {
        // Convert USDC to USDO
        uint256 usdoBase = usdoExpress.convertFromUnderlying(address(usdc), usdcAmt);

        // Reverse fee deduction (ceiling)
        uint256 redeemFeeRate = usdoExpress._redeemFeeRate();
        if (redeemFeeRate >= BASIS_POINTS) {
            return type(uint256).max;
        }
        usdoAmt =
            MathUpgradeable.mulDiv(usdoBase, BASIS_POINTS, BASIS_POINTS - redeemFeeRate, MathUpgradeable.Rounding.Up);
        uint256 _BUFFER_WEI = BUFFER_WEI * DECIMALS_OFFSET_SCALE;
        usdoAmt += _BUFFER_WEI;
    }

    function minDeposit() public view returns (uint256) {
        return previewMint(_getMintMinimum());
    }

    function minMint() public view returns (uint256) {
        return _getMintMinimum();
    }

    function minRedeem() public view returns (uint256) {
        return _getRedeemMinimum();
    }

    // ============ View Functions ============

    /**
     * @notice Total USDC value of all unclaimed redeem requests (based on previewed amounts)
     * @dev Uses usdcPreviewed as it's deterministic at request time and provides
     *      conservative estimates for reserve calculations.
     */
    function totalRedeemedUsdcAmt() public view returns (uint256) {
        return accRedeemRequestedPreviewedAmt[lastRedeemRequestId] - accClaimedPreviewedAmt;
    }

    function isKyced() external view returns (bool) {
        return usdoExpress._kycList(address(this));
    }

    function getQueuedRedemption() external view returns (uint256 queuedUsdoAmt) {
        queuedUsdoAmt = _getQueuedRedemption();
    }

    function isClaimable(uint256 redeemRequestId) public view returns (bool) {
        (string memory reason,) = _isClaimable(redeemRequestId);
        return bytes(reason).length == 0;
    }

    function isStrategy(address strategy) external view returns (bool) {
        return _strategiesSet.contains(strategy);
    }

    /// @dev Off-chain use only. May DoS if list is large.
    function getStrategies() external view returns (address[] memory) {
        return _strategiesSet.values();
    }

    /// @dev Off-chain use only. May DoS if list is large.
    function getUnclaimedRedeemRequestIds() external view returns (uint256[] memory) {
        return _unclaimedRedeemRequestIds.values();
    }

    function getUnclaimedRedeemRequestCount() external view returns (uint256) {
        return _unclaimedRedeemRequestIds.length();
    }

    // ============ Governance Functions ============

    /**
     * @notice Set the cooldown period for redeem requests
     * @dev Changes only affect NEW requests. Existing requests retain their original cooldown period
     *      since each RedeemRequest stores the cooldownPeriod at creation time.
     * @param _cooldownPeriod New cooldown period in seconds
     */
    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyGovernance {
        if (_cooldownPeriod > MAX_COOLDOWN_PERIOD) revert CooldownPeriodTooLong();
        cooldownPeriod = _cooldownPeriod;
        emit CooldownPeriodUpdated(_cooldownPeriod);
    }

    /**
     * @notice Set the health check contract address
     * @param newHealthCheck Address of the new health check contract (must have code if non-zero)
     */
    function setHealthCheck(address newHealthCheck) external onlyGovernance {
        if (newHealthCheck != address(0) && newHealthCheck.code.length == 0) revert InvalidHealthCheck();

        address oldHealthCheck = address(healthCheck);
        healthCheck = IHealthCheck(newHealthCheck);

        emit HealthCheckUpdated(oldHealthCheck, newHealthCheck);
    }

    /**
     * @notice Enable or disable health check validation
     * @param newDoHealthCheck True to enable health check validation, false to disable
     */
    function setDoHealthCheck(bool newDoHealthCheck) external onlyGovernance {
        doHealthCheck = newDoHealthCheck;
        emit SetDoHealthCheck(newDoHealthCheck);
    }

    /**
     * @notice Set the hooks contract for execution callbacks
     * @dev ERC-6900 style hooks. Set to address(0) to disable hooks.
     * @param _hooks Address of the hooks contract (must have code if non-zero)
     */
    function setHooks(address _hooks) external onlyGovernance {
        if (_hooks != address(0) && _hooks.code.length == 0) revert InvalidHooks();

        address oldHooks = hooks;
        hooks = _hooks;

        emit HooksUpdated(oldHooks, _hooks);
    }

    function addStrategy(address strategy) external onlyGovernance {
        if (strategy == address(0)) revert InvalidAddress();
        if (_strategiesSet.contains(strategy)) revert StrategyAlreadyAdded();

        _strategiesSet.add(strategy);
        emit StrategyAdded(strategy);
    }

    /**
     * @notice Remove a strategy from the whitelist
     * @dev After removal:
     *      - Pending redeem requests from this strategy remain valid and claimable (intended behavior)
     *      - Claims can be executed by either the original strategy or governance
     *      - New deposit() and redeem() calls from this strategy will be rejected
     */
    function removeStrategy(address strategy) external onlyGovernance {
        if (!_strategiesSet.contains(strategy)) revert StrategyNotFound();

        _strategiesSet.remove(strategy);
        emit StrategyRemoved(strategy);
    }

    /**
     * @notice Recalculate _historicalMinRedeemAmt from unclaimed requests
     * @dev Use when external _redeemMinimum has increased and _historicalMinRedeemAmt needs updating.
     *      WARNING: May cause DoS if _unclaimedRedeemRequestIds is very large.
     *      Consider calling only when unclaimed request count is manageable.
     */
    function syncHistoricalMinRedeemAmt() external onlyGovernance {
        uint256 length = _unclaimedRedeemRequestIds.length();
        if (length == 0) {
            _historicalMinRedeemAmt = 0;
            emit HistoricalMinRedeemAmtSynced(0);
            return;
        }

        uint256 minUsdoAmt = type(uint256).max;
        for (uint256 i = 0; i < length;) {
            uint256 requestId = _unclaimedRedeemRequestIds.at(i);
            uint256 usdoAmt = redeemRequests[requestId].usdoAmt;
            if (usdoAmt < minUsdoAmt) {
                minUsdoAmt = usdoAmt;
            }
            unchecked {
                ++i;
            }
        }

        // Apply buffer for rebasing tolerance (use 1 instead of 0 to prevent reset attack)
        uint256 buffer = BUFFER_WEI * DECIMALS_OFFSET_SCALE;
        _historicalMinRedeemAmt = minUsdoAmt > buffer ? minUsdoAmt - buffer : 1;

        emit HistoricalMinRedeemAmtSynced(_historicalMinRedeemAmt);
    }

    /**
     * @notice Submit governance transfer (step 1/2)
     */
    function submitGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert InvalidAddress();

        pendingGovernance = newGovernance;
        emit GovernanceTransferSubmitted(newGovernance);
    }

    /**
     * @notice Accept governance transfer (step 2/2)
     */
    function acceptGovernanceTransfer() external {
        if (pendingGovernance == address(0)) revert ChangeNotSubmitted();
        if (_msgSender() != pendingGovernance) revert OnlyPendingGovernance();

        address oldGovernance = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);

        emit GovernanceTransferred(oldGovernance, governance);
    }

    function pause() external onlyGovernance {
        _pause();
    }

    function unpause() external onlyGovernance {
        _unpause();
    }

    /**
     * @notice Recover excess USDC that exceeds pending redemption obligations
     * @dev Only recovers USDC surplus (donations, rounding gains, etc.) beyond totalRedeemedUsdcAmt.
     *      Claimers' reserved funds are protected - only the excess is transferable.
     * @param to Destination address for recovered USDC
     */
    function recover(address to) external onlyGovernance {
        if (to == address(0)) revert InvalidAddress();

        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 _totalRedeemedUsdcAmt = totalRedeemedUsdcAmt();
        if (usdcBalance > _totalRedeemedUsdcAmt) {
            uint256 amount = usdcBalance - _totalRedeemedUsdcAmt;
            usdc.safeTransfer(to, amount);
            emit Recovered(to, amount);
        }
    }

    /**
     * @notice Emergency function to withdraw any tokens from this contract
     * @dev Only callable when paused. For emergency fund recovery.
     * WARNING: Minimal validation. Governance must not withdraw tokens for pending redeems.
     */
    function emergencyWithdraw(address token, uint256 amount, address to) external onlyGovernance whenPaused {
        if (to == address(0)) revert InvalidAddress();

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdrawn(token, to, amount);
    }

    /**
     * Storage usage (USDOKycedCA specific): 18 slots
     *   - governance: 1 slot
     *   - pendingGovernance: 1 slot
     *   - usdoExpress: 1 slot
     *   - usdc: 1 slot
     *   - usdo: 1 slot
     *   - _strategiesSet: 2 slots
     *   - _unclaimedRedeemRequestIds: 2 slots
     *   - redeemRequests mapping: 1 slot
     *   - accRedeemRequestedPreviewedAmt mapping: 1 slot
     *   - lastRedeemRequestId: 1 slot
     *   - cooldownPeriod: 1 slot
     *   - doHealthCheck + healthCheck (packed): 1 slot
     *   - totalRedeemedUsdoAmt: 1 slot
     *   - accClaimedPreviewedAmt: 1 slot
     *   - _historicalMinRedeemAmt: 1 slot
     *   - hooks: 1 slot
     *
     * Gap = 50 - 18 = 32
     */
    uint256[32] private __gap;
}
