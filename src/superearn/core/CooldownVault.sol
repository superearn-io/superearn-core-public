// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20WrapperUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import { IERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IERC20MetadataUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { MathUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import { ICooldownVault } from "@superearn/interface/ICooldownVault.sol";
import { IStrategy } from "@superearn/interface/IStrategy.sol";
import { IStrategyCooldownAware } from "@superearn/interface/IStrategyCooldownAware.sol";
import { IGeneralHealthCheck } from "@superearn/interface/IHealthCheck.sol";

/**
 * @title CooldownVault
 * @notice ERC4626-based vault with two-step withdrawal and debt accounting
 * @dev Key innovation: 1:1 share-to-asset ratio maintained through debt mechanism
 * @dev totalAssets = (underlying + totalDebt) - totalLockedAssets
 * @dev Share price is always 1:1 - strategies cannot return profit, losses are tracked as strategyDebt
 * @dev Locked assets are reserved for pending redemptions and excluded from active share value
 * @dev CRITICAL: Governance must be MultiSig/DAO with high security
 */
contract CooldownVault is
    Initializable,
    ERC20WrapperUpgradeable,
    ERC20PermitUpgradeable,
    IERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ICooldownVault
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using MathUpgradeable for uint256;

    // === Custom Errors ===

    // Authorization Errors
    error OnlyGovernance();
    error OnlyPendingGovernance();
    error OnlyManagers();
    error OnlyStrategy();
    error OnlyKeepers();

    // Validation Errors
    error ZeroShareRedemptionNotAllowed();
    error InvalidReceiver();
    error InvalidGovernance();
    error InvalidStrategy();
    error HealthCheckFailed();
    error MaxLossExceed10000();

    // State Errors
    error ExceededMaxInstantRedeem();
    error FailedToClaim(string reason);
    error RequestAlreadyClaimed();
    error OnlyReceiver();
    error StrategyAlreadyAdded();
    error StrategyNotFound();
    error AddressAlreadyAdded();
    error AddressNotFound();
    error InvalidAddress();

    // Timing Errors
    error CooldownPeriodTooLong();
    error ChangeNotSubmitted();

    // Health Check Errors
    error InvalidHealthCheck();

    // Predeposit/Debt Errors
    error InvalidPredepositId();
    error DebtUnretrievable();
    error DebtAlreadyRepaid();
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 maxAssets);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 maxShares);
    error InsufficientManagedAssets(uint256 requested, uint256 available);
    error AssetBackingMismatch(uint256 expected, uint256 actual);
    error RetrieveAmountExceedsDebt(uint256 repay, uint256 maxRepayable);
    error RetrieveAmountExceedsShortfall(uint256 repay, uint256 maxRepayable);
    error DebtPaymentMismatch(uint256 reported, uint256 received);
    error UnauthorizedCaller();
    error UnauthorizedHolder();

    // === Constants ===
    uint256 private constant MAX_COOLDOWN_PERIOD = 365 days;
    uint256 private constant BASIS_POINTS = 10_000; // 100% = 10,000 basis points

    // === State Variables ===

    // Admins
    address public governance;
    address public pendingGovernance;
    address public management;

    // Health Check
    bool public doHealthCheck;
    IGeneralHealthCheck public healthCheck;

    // Cooldown
    uint256 public cooldownPeriod;
    uint256 public pendingCooldownPeriod;
    bool public hasPendingCooldownPeriod;

    /**
     * @notice Maximum loss threshold in basis points for third-party claims
     * @dev If maxLoss exceeds this threshold, only receiver can claim
     * @dev Default: 1 bps = 0.01%
     */
    uint256 public maxLossThresholdBps;

    // Request Tracking
    uint256 public lastRequestId;
    uint256 public lastPredepositId;

    // accRedeemRequestAmount: sum of all redeem requests amount by requestId less than key value
    // accClaimedAmount: sum of all claimed amount
    mapping(uint256 => uint256) public accRedeemRequestedAmount;
    uint256 public accClaimedAmount;

    // Debt and Asset Accounting
    /**
     * @notice Total debt owed by strategies via predeposit mechanism
     * @dev Increases when strategies predeposit shares, decreases when debt is repaid
     */
    uint256 public totalDebt;
    uint256 public totalClaimLoss;

    /**
     * @notice Total assets locked in pending redemption requests
     * @dev Assets that are allocated to unclaimed redemption requests
     */
    uint256 public totalLockedAssets;

    /// @notice Tracks recognized assets that entered via sanctioned flows
    uint256 private _managedAssets;
    /// @notice Sum of predeposit debts not repaid even after cooldown
    uint256 public totalShortfall;

    // Request Storage
    mapping(uint256 => RedeemRequest) public redeemRequests;
    mapping(uint256 => PredepositRequest) public predepositRequests;

    // Strategy Management
    EnumerableSet.AddressSet private _strategiesSet;

    /// @notice Debt not repaid when a predeposit is claimed; always a subset of strategyDebtOutstanding
    mapping(address => uint256) public strategyShortfall;
    /// @notice Outstanding predeposit debt per strategy awaiting repayment (includes any strategyShortfall)
    mapping(address => uint256) public strategyDebtOutstanding;

    // Unclaimed Tracking
    EnumerableSet.UintSet private _unclaimedRedeemRequestIds;
    EnumerableSet.UintSet private _unclaimedPredepositRequestIds;

    mapping(address => uint256) private _pendingReceiverAssets;

    // Authorized addresses
    EnumerableSet.AddressSet private _authorizedAddresses;

    // === Modifiers ===

    modifier onlyGovernance() {
        if (_msgSender() != governance) revert OnlyGovernance();
        _;
    }

    modifier onlyManagers() {
        if (_msgSender() != management && _msgSender() != governance) revert OnlyManagers();
        _;
    }

    modifier onlyStrategy() {
        if (!_strategiesSet.contains(_msgSender())) revert OnlyStrategy();
        _;
    }

    modifier onlyAuthorized() {
        if (!_authorizedAddresses.contains(_msgSender())) revert UnauthorizedCaller();
        _;
    }

    // === Constructor ===

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IERC20 _underlying,
        string memory _name,
        string memory _symbol,
        uint256 _cooldownPeriod,
        address _governance
    )
        public
        initializer
    {
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __ERC20Wrapper_init(IERC20Upgradeable(address(_underlying)));
        __ReentrancyGuard_init();
        __Pausable_init();

        if (_cooldownPeriod > MAX_COOLDOWN_PERIOD) revert CooldownPeriodTooLong();
        if (_governance == address(0)) revert InvalidGovernance();

        cooldownPeriod = _cooldownPeriod;
        governance = _governance;
        maxLossThresholdBps = 1; // Default: 0.01%, same as yVault default
    }

    // ============================================
    // ERC20Wrapper AND ERC20 OVERRIDES
    // ============================================

    function depositFor(address account, uint256 amount) public override whenNotPaused onlyAuthorized returns (bool) {
        bool success = super.depositFor(account, amount);
        if (success) {
            _increaseManagedAssetsChecked(amount);
        }
        return success;
    }

    function withdrawTo(address account, uint256 amount) public override whenNotPaused onlyAuthorized returns (bool) {
        uint256 requestId = redeem(amount, account, _msgSender());
        return requestId > 0;
    }

    function _requireAuthorizedHolder(address account) internal view {
        if (account == address(0)) revert InvalidAddress();
        if (!_authorizedAddresses.contains(account)) revert UnauthorizedHolder();
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    )
        internal
        virtual
        override(ERC20Upgradeable)
    {
        if (from != address(0)) {
            _requireAuthorizedHolder(from);
        }
        if (to != address(0)) {
            _requireAuthorizedHolder(to);
        }
        super._beforeTokenTransfer(from, to, amount);
    }

    // ============================================
    // ERC4626 OVERRIDES
    // ============================================

    function asset() external view override returns (address assetTokenAddress) {
        assetTokenAddress = address(underlying());
    }

    /**
     * @notice Calculate total assets backing the vault shares
     * @dev Returns (underlying + totalDebt) - totalLockedAssets
     * @dev This value always equals totalSupply, maintaining 1:1 share-to-asset ratio
     * @return Total available assets for share calculations
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 assets = _managedAssets + totalDebt;
        if (assets > totalLockedAssets) {
            return assets - totalLockedAssets;
        } else {
            return 0;
        }
    }

    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        shares = assets;
    }

    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        assets = shares;
    }

    function maxDeposit(address /* receiver */ ) external view override returns (uint256 maxAssets) {
        return type(uint256).max;
    }

    function maxMint(address /* receiver */ ) external view override returns (uint256 maxShares) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256 maxAssets) {
        maxAssets = balanceOf(owner);
    }

    function maxRedeem(address owner) public view override returns (uint256 maxShares) {
        maxShares = balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        shares = assets;
    }

    function previewMint(uint256 shares) public view override returns (uint256 assets) {
        assets = shares;
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 shares) {
        shares = assets;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256 assets) {
        assets = shares;
    }

    /**
     * @dev See {IERC4626-deposit}.
     * @dev Protected by pause and reentrancy guards
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        virtual
        override(IERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        onlyAuthorized
        returns (uint256)
    {
        // depositFor always returns true or reverts, never false
        depositFor(receiver, assets);
        return assets;
    }

    /**
     * @dev See {IERC4626-mint}.
     * @dev Protected by pause and reentrancy guards
     */
    function mint(
        uint256 shares,
        address receiver
    )
        public
        virtual
        override(IERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        onlyAuthorized
        returns (uint256)
    {
        // depositFor always returns true or reverts, never false
        depositFor(receiver, shares);
        return shares;
    }

    /**
     * @notice Request withdrawal of assets (two-step process)
     * @dev Unlike standard ERC4626, initiates a cooldown period before assets can be claimed
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive assets after cooldown
     * @param owner Address whose shares will be burned
     * @return requestId Unique identifier for the redemption request
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        virtual
        override(IERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        onlyAuthorized
        returns (uint256 requestId)
    {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        uint256 shares = previewWithdraw(assets);
        requestId = _initiateRedemption(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @notice Request redemption of shares (two-step process)
     * @dev Unlike standard ERC4626, initiates a cooldown period before assets can be claimed
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive assets after cooldown
     * @param owner Address whose shares will be burned
     * @return requestId Unique identifier for the redemption request
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        virtual
        override(IERC4626Upgradeable)
        whenNotPaused
        nonReentrant
        onlyAuthorized
        returns (uint256 requestId)
    {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        uint256 assets = previewRedeem(shares);
        requestId = _initiateRedemption(_msgSender(), receiver, owner, assets, shares);
    }

    /**
     * @dev Override decimals to resolve multiple inheritance conflict
     */
    function decimals()
        public
        view
        virtual
        override(IERC20MetadataUpgradeable, ERC20Upgradeable, ERC20WrapperUpgradeable)
        returns (uint8)
    {
        return super.decimals();
    }

    // ============================================
    // INTERNAL REDEMPTION LOGIC
    // ============================================

    /**
     * @notice Internal function to initiate redemption request
     * @dev Burns shares immediately and locks assets for cooldown period
     * @param caller Address initiating the redemption
     * @param receiver Address to receive assets after cooldown
     * @param owner Address whose shares are being redeemed
     * @param assets Amount of assets to be redeemed
     * @param shares Amount of shares to burn
     * @return requestId Unique identifier for the redemption request
     */
    function _initiateRedemption(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        returns (uint256 requestId)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (shares == 0) revert ZeroShareRedemptionNotAllowed();

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Burn shares
        _burn(owner, shares);

        totalLockedAssets += assets;

        // Create request
        unchecked {
            requestId = ++lastRequestId;
        }
        redeemRequests[requestId] = RedeemRequest({
            receiver: receiver,
            assets: assets,
            cooldownRequestedTime: block.timestamp,
            cooldownPeriod: cooldownPeriod,
            claimed: false
        });

        accRedeemRequestedAmount[requestId] = accRedeemRequestedAmount[requestId - 1] + assets;

        _unclaimedRedeemRequestIds.add(requestId);
        _pendingReceiverAssets[receiver] += assets;

        emit RedeemRequested(caller, receiver, requestId, assets, shares, block.timestamp);

        if (cooldownPeriod == 0) {
            uint256 minAssetsOut = MathUpgradeable.mulDiv(assets, BASIS_POINTS - maxLossThresholdBps, BASIS_POINTS);
            // ignore failure; can claim later after liquidity becomes available
            _claim(requestId, minAssetsOut);
        }
    }

    /**
     * @notice Claim assets from a completed cooldown redemption request
     * @dev Can only be called after cooldown period has elapsed
     * @param requestId Unique identifier of the redemption request
     * @param maxLossBps Maximum acceptable loss in basis points (e.g., 100 = 1% slippage tolerance)
     * @dev Reverts if maxLossBps exceeds 10,000 (100%)
     * @dev Third-party claims allowed: If maxLossBps <= maxLossThresholdBps (default=1, i.e., 0.01%),
     *      anyone can claim on behalf of the receiver. This enables meta-transactions, gasless claims,
     *      and improved UX through automated claim services.
     * @return claimable Actual amount of assets claimed
     */
    function claim(
        uint256 requestId,
        uint256 maxLossBps
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 claimable)
    {
        if (requestId > lastRequestId || requestId == 0) revert FailedToClaim("INVALID_REQUEST_ID");
        if (maxLossBps > BASIS_POINTS) revert MaxLossExceed10000();

        RedeemRequest memory request = redeemRequests[requestId];

        // High slippage protection: Only receiver can claim with high maxLoss
        if (maxLossBps > maxLossThresholdBps && _msgSender() != request.receiver) {
            revert FailedToClaim("ONLY_RECEIVER");
        }

        // Set loss tolerance
        uint256 minAssetsOut = MathUpgradeable.mulDiv(request.assets, BASIS_POINTS - maxLossBps, BASIS_POINTS);

        // Execute claim
        string memory reason;
        (reason, claimable) = _claim(requestId, minAssetsOut);
        if (bytes(reason).length > 0) {
            revert FailedToClaim(reason);
        }
    }

    /**
     * @notice Update the receiver address of a pending redemption request
     * @dev Allows the current receiver to change the recipient address (e.g., if blacklisted by USDC/USDT)
     * @param requestId Unique identifier of the redemption request
     * @param newReceiver New receiver address to set
     */
    function updateRedeemReceiver(
        uint256 requestId,
        address newReceiver
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        if (newReceiver == address(0)) revert InvalidReceiver();

        RedeemRequest storage request = redeemRequests[requestId];
        if (request.claimed) revert RequestAlreadyClaimed();
        if (_msgSender() != request.receiver) revert OnlyReceiver();

        address oldReceiver = request.receiver;
        request.receiver = newReceiver;

        _pendingReceiverAssets[oldReceiver] -= request.assets;
        _pendingReceiverAssets[newReceiver] += request.assets;

        emit RedeemReceiverUpdated(requestId, oldReceiver, newReceiver);
    }

    /**
     * @notice Internal function to execute the claim of a redemption request
     * @dev **Soft Failure Pattern**: This function never reverts. All error conditions return a reason string.
     * @dev Performs actual asset transfer if cooldown period has elapsed and sufficient assets are available
     * @param requestId Unique identifier of the redemption request to claim
     * @param minAssetsOut Minimum amount of assets required for successful claim
     * @return reason Status string: empty string on success, error reason on failure
     * @return assetsOut Actual amount of assets that would be/were transferred
     */
    function _claim(
        uint256 requestId,
        uint256 minAssetsOut
    )
        internal
        returns (string memory reason, uint256 assetsOut)
    {
        // Check is claimed
        RedeemRequest storage request = redeemRequests[requestId];
        if (request.claimed) {
            return ("INVALID", 0);
        }

        // Check cooldown period
        if (block.timestamp < request.cooldownRequestedTime + request.cooldownPeriod) {
            return ("SHOULD_WAIT", 0);
        }

        // Sum of all requests before this one (requests 1 to requestId-1)
        uint256 _accRedeemRequestedAmount = accRedeemRequestedAmount[requestId - 1];

        // Before paying this request, we must ensure enough assets remain for earlier unclaimed requests.
        //
        // reservedForPriorRequests = (total requested by 1..k-1) - (total already claimed)
        //                          = amount still owed to requests before this one
        //
        // Why out-of-order claims are safe:
        // - accClaimedAmount may include claims from later requests (j > requestId)
        // - But if request j was claimed, it passed this same check, meaning:
        //   "the vault had enough for j AND all requests before j"
        // - So including j in accClaimedAmount only REDUCES reservedForPriorRequests,
        //   making this check EASIER (not harder) for earlier requests to pass.
        uint256 reservedForPriorRequests =
            _accRedeemRequestedAmount > accClaimedAmount ? _accRedeemRequestedAmount - accClaimedAmount : 0;

        // Calculate available liquidity after reserving for prior requests
        uint256 availableLiquidity =
            _managedAssets > reservedForPriorRequests ? _managedAssets - reservedForPriorRequests : 0;

        // Calculate claimable based on available unreserved liquidity
        assetsOut = MathUpgradeable.min(request.assets, availableLiquidity);
        if (assetsOut < minAssetsOut) {
            // Prior reservations prevent fulfilling this request
            if (reservedForPriorRequests > 0 && request.assets <= _managedAssets) {
                return ("INSUFFICIENT_ASSETS", 0);
            }
            return ("EXCESSIVE_LOSS", assetsOut);
        }

        // Now we can claim
        // reason = ""; means success

        // Effects
        request.claimed = true;
        totalLockedAssets -= request.assets;
        accClaimedAmount += request.assets;
        totalClaimLoss += request.assets - assetsOut;
        _unclaimedRedeemRequestIds.remove(requestId);

        _pendingReceiverAssets[request.receiver] -= request.assets;
        _decreaseManagedAssets(assetsOut);

        // Interactions
        IERC20Upgradeable(underlying()).safeTransfer(request.receiver, assetsOut);
        _assertSufficientBacking();
        emit Claimed(_msgSender(), requestId, request.assets, assetsOut);
    }

    function _increaseManagedAssets(uint256 amount) internal {
        unchecked {
            _managedAssets += amount;
        }
    }

    function _increaseManagedAssetsChecked(uint256 amount) internal {
        _increaseManagedAssets(amount);
        _assertSufficientBacking();
    }

    function _decreaseManagedAssets(uint256 amount) internal {
        uint256 managed = _managedAssets;
        if (amount > managed) revert InsufficientManagedAssets(amount, managed);
        unchecked {
            _managedAssets = managed - amount;
        }
    }

    function _assertSufficientBacking() internal view {
        uint256 actual = _actualBalance();
        if (actual < _managedAssets) revert AssetBackingMismatch(_managedAssets, actual);
    }

    function _increaseShortfall(address strategy, uint256 shortfall) internal {
        strategyShortfall[strategy] += shortfall;
        totalShortfall += shortfall;
    }

    function _decreaseShortfall(address strategy, uint256 shortfall) internal {
        strategyShortfall[strategy] -= shortfall;
        totalShortfall -= shortfall;
    }

    // ============================================
    // PREDEPOSIT AND DEBT FUNCTIONS
    // ============================================

    /**
     * @notice Pre-deposits assets by creating debt and minting shares before actual assets arrive
     * @dev Enables strategies to mint vault shares against future asset deposits:
     *
     * Problem: External protocols have cooldowns that delay asset availability:
     * 1. Initiate external redemption → 2. Wait cooldown → 3. Claim assets → 4. Deposit here
     * This creates a timing gap between initiating redemption and receiving assets.
     *
     * Solution: Predeposit allows immediate share minting when external redemption starts:
     * - Creates debt (totalDebt) representing promised future assets
     * - Mints shares immediately based on current exchange rate
     * - Debt is repaid when actual assets arrive via retrieveDebt()
     * - Enables atomic operations without waiting for external cooldowns
     *
     * @dev CRITICAL: Vault's cooldownPeriod MUST exceed all integrated protocol cooldowns
     * to ensure underlying assets are available when users claim
     *
     * @param assets Amount of assets to pre-deposit (creates equivalent debt)
     *
     * @dev Cooldown period retrieved from strategy, validation intentionally omitted:
     * 1. External protocols may change settings dynamically
     * 2. Provides operational flexibility for edge cases
     * 3. No security risk - users just experience our cooldown if external > internal
     *
     * @return predepositId ID tracking this predeposit and debt repayment
     * @return shares Amount of shares minted to the strategy
     */
    function predeposit(uint256 assets)
        external
        override
        onlyStrategy
        whenNotPaused
        nonReentrant
        returns (uint256 predepositId, uint256 shares)
    {
        shares = previewDeposit(assets);
        if (shares == 0 || assets == 0) return (0, 0);
        uint256 _cooldownPeriod = IStrategyCooldownAware(_msgSender()).getCooldownPeriod();
        if (_cooldownPeriod > cooldownPeriod) emit StrangeCooldownPeriod(cooldownPeriod, _cooldownPeriod);

        unchecked {
            predepositId = ++lastPredepositId;
        }
        predepositRequests[predepositId] = PredepositRequest({
            strategy: _msgSender(),
            shares: shares,
            debtAssets: assets,
            cooldownRequestedTime: block.timestamp,
            cooldownPeriod: _cooldownPeriod,
            claimed: false
        });

        _unclaimedPredepositRequestIds.add(predepositId);

        // Update debt tracking - new shares are backed by debt
        totalDebt += assets;
        strategyDebtOutstanding[_msgSender()] += assets;

        // Mint shares to strategy
        _mint(_msgSender(), shares);

        emit PredepositRequested(_msgSender(), predepositId, shares, assets, _cooldownPeriod);
    }

    /**
     * @notice Retrieve debt payment from strategy after cooldown
     * @dev Strategy must have deposited assets to cover the debt
     * @param predepositId Unique identifier of the predeposit request
     */
    function retrieveDebt(uint256 predepositId) external override whenNotPaused nonReentrant {
        PredepositRequest storage predepositRequest = predepositRequests[predepositId];
        IStrategyCooldownAware strategy;
        {
            address _strategy = predepositRequest.strategy;
            if (_strategy == address(0)) revert InvalidPredepositId();
            _requireOnlyKeepers(_strategy, _msgSender());

            strategy = IStrategyCooldownAware(_strategy);
        }
        if (predepositRequest.claimed) revert DebtAlreadyRepaid();

        // NOTE: We no longer check isPredepositAlreadyClaimed() here because strategies
        // do not support permissionless claims directly. If external protocol supports
        // permissionless claims, an Escrow/Swapper contract must be used as intermediary.
        // See docs/PERMISSIONLESS_CLAIM_ARCHITECTURE.md for details.
        if (!strategy.predepositDebtRetrievable(predepositId)) {
            revert DebtUnretrievable();
        }

        // The Strategy can repay up to predepositRequest.debtAssets
        // Verify actual asset transfer matches reported amount to prevent malicious strategy misreporting
        uint256 balanceBefore = _actualBalance();
        uint256 debtPayment = strategy.repayPredepositDebt(predepositId);
        uint256 balanceAfter = _actualBalance();
        uint256 actualReceived = balanceAfter - balanceBefore;
        if (actualReceived != debtPayment) {
            revert DebtPaymentMismatch(debtPayment, actualReceived);
        }
        if (debtPayment > predepositRequest.debtAssets) {
            revert RetrieveAmountExceedsDebt(debtPayment, predepositRequest.debtAssets);
        }

        if (doHealthCheck && address(healthCheck) != address(0)) {
            _checkHealth();
        } else {
            doHealthCheck = true;
            emit SetDoHealthCheck(true);
        }

        predepositRequest.claimed = true;
        _unclaimedPredepositRequestIds.remove(predepositId);
        totalDebt -= debtPayment;
        // Update per-strategy outstanding debt
        uint256 currentOutstanding = strategyDebtOutstanding[address(strategy)];
        if (debtPayment >= currentOutstanding) {
            strategyDebtOutstanding[address(strategy)] = 0;
        } else {
            strategyDebtOutstanding[address(strategy)] = currentOutstanding - debtPayment;
        }

        if (predepositRequest.debtAssets > debtPayment) {
            uint256 shortfall = predepositRequest.debtAssets - debtPayment;
            _increaseShortfall(address(strategy), shortfall);
            emit StrategyDebtShortfall(address(strategy), predepositId, shortfall);
        }
        _increaseManagedAssetsChecked(debtPayment);

        emit DebtRetrieved(predepositRequest.strategy, predepositId, predepositRequest.debtAssets, debtPayment);
    }

    /**
     * @notice Validates the health of a debt repayment transaction
     * @dev Reverts with HealthCheckFailed if the health check contract rejects the transaction
     */
    function _checkHealth() internal view {
        if (!healthCheck.check()) {
            revert HealthCheckFailed();
        }
    }

    function _requireOnlyKeepers(address strategy, address caller) internal view {
        if (!_strategiesSet.contains(strategy)) revert OnlyKeepers();

        IStrategy yStrategy = IStrategy(strategy);
        if (
            caller != management && caller != governance && caller != yStrategy.keeper()
                && caller != yStrategy.strategist()
        ) revert OnlyKeepers();
    }

    // ============================================
    // STRATEGY-SPECIFIC FUNCTIONS
    // ============================================

    /**
     * @notice Calculate maximum shares redeemable instantly (no cooldown)
     * @dev Only strategies can use instant redemption, limited by idle assets
     * @param caller Address requesting instant redemption
     * @return maxShares Maximum shares that can be redeemed instantly
     */
    function maxInstantRedeem(address caller) public view override returns (uint256 maxShares) {
        uint256 idle = idleBalance();
        uint256 callerBalance = balanceOf(caller);
        maxShares = MathUpgradeable.min(previewDeposit(idle), callerBalance);
    }

    /**
     * @notice Instantly redeem shares without cooldown (strategies only)
     * @dev Bypasses cooldown for strategy rebalancing operations
     * @param shares Amount of shares to redeem instantly
     */
    function instantRedeem(uint256 shares)
        external
        override
        onlyStrategy
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) return 0;
        if (maxInstantRedeem(_msgSender()) < shares) revert ExceededMaxInstantRedeem();

        assets = previewRedeem(shares);
        _burn(_msgSender(), shares);
        _decreaseManagedAssets(assets);

        IERC20Upgradeable(underlying()).safeTransfer(_msgSender(), assets);
        _assertSufficientBacking();
        emit InstantRedemption(_msgSender(), shares, assets);
    }

    /**
     * @notice Repay strategy debt shortfall
     * @param assets Amount of assets to repay
     */
    function retrieveShortfall(uint256 assets) external override onlyStrategy whenNotPaused nonReentrant {
        address strategy = _msgSender();
        uint256 shortfall = strategyShortfall[strategy];
        if (assets > shortfall) revert RetrieveAmountExceedsShortfall(assets, shortfall);

        // Effects
        _decreaseShortfall(strategy, assets);
        totalDebt -= assets;
        uint256 currentOutstanding = strategyDebtOutstanding[strategy];
        if (assets >= currentOutstanding) {
            strategyDebtOutstanding[strategy] = 0;
        } else {
            strategyDebtOutstanding[strategy] = currentOutstanding - assets;
        }

        IERC20Upgradeable(underlying()).safeTransferFrom(strategy, address(this), assets);
        _increaseManagedAssetsChecked(assets);

        emit StrategyDebtRepaid(strategy, assets, strategyShortfall[strategy]);
    }

    // ============================================
    // GOVERNANCE FUNCTIONS
    // ============================================

    /**
     * @notice Submit cooldown period change (step 1/2)
     * @param _cooldownPeriod New cooldown in seconds
     */
    function submitCooldownPeriod(uint256 _cooldownPeriod) external override onlyGovernance {
        if (_cooldownPeriod > MAX_COOLDOWN_PERIOD) revert CooldownPeriodTooLong();
        pendingCooldownPeriod = _cooldownPeriod;
        hasPendingCooldownPeriod = true;
        emit CooldownPeriodSubmitted(_cooldownPeriod);
    }

    /**
     * @notice Accept cooldown period change (step 2/2)
     */
    function acceptCooldownPeriod() external override onlyGovernance {
        if (!hasPendingCooldownPeriod) revert ChangeNotSubmitted();

        cooldownPeriod = pendingCooldownPeriod;
        pendingCooldownPeriod = 0;
        hasPendingCooldownPeriod = false;

        emit CooldownPeriodUpdated(cooldownPeriod);
    }

    /**
     * @notice Submit governance transfer (step 1/2)
     * @param newGovernance Proposed governance address
     */
    function submitGovernanceTransfer(address newGovernance) external override onlyGovernance {
        if (newGovernance == address(0)) revert InvalidGovernance();

        pendingGovernance = newGovernance;
        emit GovernanceTransferSubmitted(newGovernance);
    }

    /**
     * @notice Accept governance role (step 2/2)
     */
    function acceptGovernanceTransfer() external override {
        if (pendingGovernance == address(0)) revert ChangeNotSubmitted();
        if (_msgSender() != pendingGovernance) revert OnlyPendingGovernance();

        address oldGovernance = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);

        emit GovernanceTransferred(oldGovernance, governance);
    }

    /**
     * @notice Set the management address
     * @dev Management has permissions to manage health check settings alongside governance
     * @param newManagement Address of the new management (can be zero address to remove)
     */
    function setManagement(address newManagement) external override onlyGovernance {
        management = newManagement;
        emit UpdateManagement(newManagement);
    }

    /**
     * @notice Add strategy to whitelist
     * @param strategy Strategy address
     */
    function addStrategy(address strategy) external override onlyGovernance {
        if (strategy == address(0)) revert InvalidStrategy();
        if (_strategiesSet.contains(strategy)) revert StrategyAlreadyAdded();

        _strategiesSet.add(strategy);
        emit StrategyAdded(strategy);

        if (!_authorizedAddresses.contains(strategy)) {
            _addAuthorizedAddress(strategy);
        }
    }

    /**
     * @notice Remove strategy from whitelist
     * @dev WARNING: Check if the strategy has any unclaimed predeposit requests before removal.
     *      It is recommended to retrieve all debts and remove all predeposit requests before removing the strategy.
     *      However, as this is a governance-only function for exceptional situations,
     *      validation is skipped to allow removal even with existing predeposits.
     * @param strategy Strategy address
     */
    function removeStrategy(address strategy) external override onlyGovernance {
        if (!_strategiesSet.contains(strategy)) revert StrategyNotFound();

        _strategiesSet.remove(strategy);
        emit StrategyRemoved(strategy);

        if (_authorizedAddresses.contains(strategy)) {
            _removeAuthorizedAddress(strategy);
        }
    }

    function addAuthorizedAddress(address authorizedAddress) external override onlyGovernance {
        if (authorizedAddress == address(0)) revert InvalidAddress();
        if (_authorizedAddresses.contains(authorizedAddress)) revert AddressAlreadyAdded();
        _addAuthorizedAddress(authorizedAddress);
    }

    function _addAuthorizedAddress(address target) internal {
        _authorizedAddresses.add(target);
        emit AuthorizedAddressAdded(target);
    }

    function removeAuthorizedAddress(address authorizedAddress) external override onlyGovernance {
        if (!_authorizedAddresses.contains(authorizedAddress)) revert AddressNotFound();
        _removeAuthorizedAddress(authorizedAddress);
    }

    function _removeAuthorizedAddress(address target) internal {
        _authorizedAddresses.remove(target);
        emit AuthorizedAddressRemoved(target);
    }

    /**
     * @notice Pause vault operations
     */
    function pause() external override onlyManagers {
        _pause();
    }

    /**
     * @notice Unpause vault operations
     */
    function unpause() external override onlyGovernance {
        _unpause();
    }

    /**
     * @notice Set maximum loss threshold for third-party claims
     * @param _maxLossThresholdBps New threshold in basis points (e.g., 10 = 0.1%)
     */
    function setMaxLossThresholdBps(uint256 _maxLossThresholdBps) external override onlyManagers {
        _maxLossThresholdBps = MathUpgradeable.min(_maxLossThresholdBps, BASIS_POINTS);

        uint256 oldThreshold = maxLossThresholdBps;
        maxLossThresholdBps = _maxLossThresholdBps;
        emit MaxLossThresholdUpdated(oldThreshold, _maxLossThresholdBps);
    }

    /**
     * @notice Set the health check contract address
     * @dev Health check validates debt repayments from strategies to prevent excessive losses
     * @dev Can be set to zero address to disable health check contract (doHealthCheck still applies)
     * @param newHealthCheck Address of the new health check contract (must have code if non-zero)
     */
    function setHealthCheck(address newHealthCheck) external override onlyManagers {
        if (newHealthCheck != address(0) && newHealthCheck.code.length == 0) revert InvalidHealthCheck();

        address oldHealthCheck = address(healthCheck);
        healthCheck = IGeneralHealthCheck(newHealthCheck);

        emit HealthCheckUpdated(oldHealthCheck, newHealthCheck);
    }

    /**
     * @notice Enable or disable health check validation
     * @dev When enabled, debt repayments are validated through the healthCheck contract
     * @dev Automatically re-enabled to true after first successful retrieveDebt() if disabled
     * @param newDoHealthCheck True to enable health check validation, false to temporarily disable
     */
    function setDoHealthCheck(bool newDoHealthCheck) external override onlyManagers {
        doHealthCheck = newDoHealthCheck;
        emit SetDoHealthCheck(newDoHealthCheck);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get vault's actual underlying asset balance
     * @return actualUnderlyingBalance
     */
    function _actualBalance() internal view returns (uint256) {
        return IERC20Upgradeable(underlying()).balanceOf(address(this));
    }

    /**
     * @notice Get vault's managed underlying asset balance
     * @return _managedAssets
     */
    function assetBalance() public view override returns (uint256) {
        return _managedAssets;
    }

    /**
     * @notice Calculate the amount of underlying assets available for immediate use
     * @dev Returns assets not locked in pending redemption requests
     * @dev Idle balance = underlying balance - locked assets reserved for claims
     * @return Amount of assets available for instant redemption or strategy allocation
     */
    function idleBalance() public view override returns (uint256) {
        if (_managedAssets > totalLockedAssets) {
            return _managedAssets - totalLockedAssets;
        } else {
            return 0;
        }
    }

    /**
     * @notice Check if address is whitelisted strategy
     * @param strategy Address to check
     * @return Whether strategy is whitelisted
     */
    function isStrategy(address strategy) external view override returns (bool) {
        return _strategiesSet.contains(strategy);
    }

    /**
     * @notice Get all whitelisted strategies
     * @return Array of strategy addresses
     */
    function getStrategies() external view override returns (address[] memory) {
        return _strategiesSet.values();
    }

    function getAuthorizedAddresses() external view override returns (address[] memory) {
        return _authorizedAddresses.values();
    }

    /**
     * @notice Get redemption request details
     * @param requestId The request ID
     * @return request The complete RedeemRequest struct
     */
    function getRedeemRequest(uint256 requestId) external view override returns (RedeemRequest memory request) {
        return redeemRequests[requestId];
    }

    /**
     * @notice Get predeposit request details
     * @param predepositId The predeposit ID
     * @return request The complete PredepositRequest struct
     */
    function getPredepositRequest(uint256 predepositId)
        external
        view
        override
        returns (PredepositRequest memory request)
    {
        return predepositRequests[predepositId];
    }

    /**
     * @notice Get unclaimed redeem request IDs
     * @return Array of request IDs
     */
    function getUnclaimedRedeemRequestIds() external view override returns (uint256[] memory) {
        return _unclaimedRedeemRequestIds.values();
    }

    /**
     * @notice Get paginated unclaimed redeem request IDs
     * @param limit Maximum results
     * @param skip Offset for pagination
     * @return Array of request IDs
     */
    function getUnclaimedRedeemRequestIds(
        uint256 limit,
        uint256 skip
    )
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256 totalLength = _unclaimedRedeemRequestIds.length();

        if (skip >= totalLength) {
            return new uint256[](0);
        }

        uint256 remaining = totalLength - skip;
        uint256 returnLength = MathUpgradeable.min(limit, remaining);

        uint256[] memory result = new uint256[](returnLength);
        for (uint256 i = 0; i < returnLength;) {
            result[i] = _unclaimedRedeemRequestIds.at(skip + i);
            unchecked {
                i++;
            }
        }

        return result;
    }

    /**
     * @notice Get unclaimed predeposit request IDs
     * @return Array of request IDs
     */
    function getUnclaimedPredepositRequestIds() external view override returns (uint256[] memory) {
        return _unclaimedPredepositRequestIds.values();
    }

    /**
     * @notice Get paginated unclaimed predeposit request IDs
     * @param limit Maximum results
     * @param skip Offset for pagination
     * @return Array of request IDs
     */
    function getUnclaimedPredepositRequestIds(
        uint256 limit,
        uint256 skip
    )
        external
        view
        override
        returns (uint256[] memory)
    {
        uint256 totalLength = _unclaimedPredepositRequestIds.length();

        if (skip >= totalLength) {
            return new uint256[](0);
        }

        uint256 remaining = totalLength - skip;
        uint256 returnLength = MathUpgradeable.min(limit, remaining);

        uint256[] memory result = new uint256[](returnLength);
        for (uint256 i = 0; i < returnLength;) {
            result[i] = _unclaimedPredepositRequestIds.at(skip + i);
            unchecked {
                i++;
            }
        }

        return result;
    }

    function pendingAssets(address receiver) external view override returns (uint256) {
        return _pendingReceiverAssets[receiver];
    }

    // ============================================
    // RECOVERY FUNCTION
    // ============================================

    /**
     * @notice Recover excess assets that were transferred directly without going through sanctioned flows
     * @dev Transfers unmanaged balance (actual - managed) to governance
     * @return assets Amount swept
     */
    function recover() external override nonReentrant onlyGovernance returns (uint256 assets) {
        uint256 actual = _actualBalance();
        uint256 managed = _managedAssets;
        if (actual > managed) {
            unchecked {
                assets = actual - managed;
            }
            IERC20Upgradeable(underlying()).safeTransfer(_msgSender(), assets);
        }

        emit Recovered(_msgSender(), assets);
    }

    /**
     * @notice Reconcile accounting gap from claim losses by minting shares to governance
     * @dev When redemption claims transfer less assets than locked (due to insufficient vault liquidity),
     *      the difference accumulates in totalClaimLoss, creating an accounting gap
     * @dev This function resolves the gap by minting shares equal to totalClaimLoss to governance,
     *      effectively making governance absorb the loss and maintain the vault's 1:1 share-to-asset ratio
     * @return assets Amount of claim loss recovered
     */
    function recoverClaimLoss() external override nonReentrant onlyGovernance returns (uint256 assets) {
        assets = totalClaimLoss;
        _mint(_msgSender(), assets); // equals shares minted to governance
        totalClaimLoss = 0;

        emit RecoverClaimLoss(_msgSender(), assets);
    }

    /**
     * Storage usage (CooldownVault specific): 30 slots
     *   - governance/pendingGovernance: 2 slots
     *   - management + doHealthCheck (packed): 1 slot
     *   - healthCheck: 1 slot
     *   - cooldown configuration: 3 slots
     *   - maxLossThresholdBps/lastRequestId/lastPredepositId/accRedeemRequestedAmount/accClaimedAmount/totalDebt/
     *     totalClaimLoss/totalLockedAssets/_managedAssets/totalShortfall/strategyDebtOutstanding: 11 slots
     *   - redeemRequests mapping: 1 slot
     *   - predepositRequests mapping: 1 slot
     *   - _pendingReceiverAssets mapping: 1 slot
     *   - _strategiesSet: 2 slots
     *   - strategyShortfall mapping: 1 slot
     *   - _unclaimedRedeemRequestIds: 2 slots
     *   - _unclaimedPredepositRequestIds: 2 slots
     *   - _authorizedAddresses: 2 slots
     *
     * Gap = 50 - 30 = 20
     */
    uint256[20] private __gap;
}
