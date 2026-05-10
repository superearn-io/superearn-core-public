// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IERC20MetadataUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IVault } from "@superearn/interface/IVault.sol";
import { SuperEarnV2Protocol } from "../../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../../messaging/runespear/RunespearProtocol.sol";
import { AssetPriceConverter } from "../../periphery/AssetPriceConverter.sol";
import { UniversalSwapRouter } from "../../periphery/UniversalSwapRouter.sol";
import { ICrosschainVault } from "../../interfaces/ICrosschainVault.sol";
import { IRemoteVault } from "../../interfaces/IRemoteVault.sol";
import { IRunespearAgent } from "../../interfaces/IRunespearAgent.sol";
import { SuperEarnRouter } from "../../../periphery/SuperEarnRouter.sol";
import { IRegistry } from "../../../interface/IRegistry.sol";
import { ICooldownVault } from "../../../interface/ICooldownVault.sol";
import { SuperEarnAccessControl } from "../../base/SuperEarnAccessControl.sol";
import { RemoteVaultStorageGap } from "../../base/RemoteVaultStorageGap.sol";
import { ICustomStrategy } from "../../interfaces/ICustomStrategy.sol";

/**
 * @title RemoteVault
 * @notice Vault on Ethereum that receives crosschain messages from Origin and manages Yearn vault positions
 * @dev Crosschain messaging handled by CrosschainAdapter
 *
 * @custom:storage-layout-compatibility
 *      This contract inherits RemoteVaultStorageGap to maintain storage layout compatibility
 *      with v1.0.0-eth deployment which inherited ERC4626Upgradeable.
 *      The RemoteVaultStorageGap reserves 100 storage slots (ERC20: 50 + ERC4626: 50)
 *      that were previously occupied by the ERC4626 inheritance chain.
 */
contract RemoteVault is
    Initializable,
    RemoteVaultStorageGap,
    IRemoteVault,
    SuperEarnAccessControl,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Math for uint256;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // Constants & Immutables
    // ============================================

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant DEFAULT_MAX_SLIPPAGE_BPS = 50; // 0.5%

    // ============================================
    // Infrastructure
    // ============================================

    // Yearn Vault Configs

    //yearn vault using cooldown vault based on USDC
    address public usdcYearnVault;
    uint256 public maxSlippageBps = DEFAULT_MAX_SLIPPAGE_BPS;

    // Price Feeds & Swap Infrastructure
    /// @dev Used to convert between USDT and USDC for origin communication
    address public usdtPriceFeed;
    address public usdcPriceFeed;
    /// @dev Price converter contract for Chainlink price feeds
    AssetPriceConverter public priceConverter;
    UniversalSwapRouter public swapRouter;
    SuperEarnRouter public superEarnRouter;

    // Crosschain Communication
    /// @dev Agent handles routing to/from origin.
    IRunespearAgent public agent;

    address public usdt;
    uint256 public usdcDecimals;
    uint256 public usdtDecimals;

    // ============================================
    // State Variables
    // ============================================

    // Withdrawal Queue
    /// @dev Tracks unfulfilled withdrawals in USDT when liquidity is short.
    uint256 public unfulfilledWithdrawalAmount;

    // @dev Asset address - placed here to maintain storage layout compatibility
    //      with v1.0.0-eth where this slot was occupied by whitelistedDepositors mapping
    //      Note: This variable replaces ERC4626's internal _asset which was removed
    address public usdc;

    //yearn vault using cooldown vault based on USDT
    address public usdtYearnVault;

    // ============================================
    // Custom Strategy Management
    // ============================================

    /// @notice Array of registered custom strategies
    address[] public customStrategies;
    /// @notice Mapping to check if an address is a registered custom strategy
    mapping(address => bool) public isCustomStrategy;
    /// @notice Mapping to store index+1 of strategy in array (0 means not in array)
    mapping(address => uint256) private __customStrategyIndex;

    // ============================================
    // Events
    // ============================================

    event YearnVaultSet(address indexed vault, bool isUsdc);
    event DepositedToYearn(uint256 amount, uint256 shares);
    event YearnRedemptionInitiated(
        uint256 indexed requestId, uint256 ySharesRedeemed, uint256 expectedAssets, uint256 timestamp
    );
    event EmergencyWithdrawn(uint256 amount);
    event PriceFeedsUpdated(address usdtFeed, address usdcFeed);
    event PriceConverterUpdated(address indexed priceConverter);
    event UnfulfilledWithdrawalIncreased(uint256 addedAmount, uint256 totalUnfulfilled);
    event UnfulfilledWithdrawalFulfilled(uint256 fulfilledAmount, uint256 remainingUnfulfilled);
    event SuperEarnRouterSet(address indexed router);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amount, uint256 amountOut);
    event CustomStrategyAdded(address indexed strategy);
    event CustomStrategyRemoved(address indexed strategy);
    event DepositedToCustomStrategy(address indexed strategy, address indexed token, uint256 amount);
    event WithdrawnFromCustomStrategy(address indexed strategy, address indexed token, uint256 amount);

    // ============================================
    // Role Reporting
    // ============================================

    function vaultRole() external pure override returns (VaultRole) {
        return VaultRole.Remote;
    }

    // ============================================
    // Errors
    // ============================================

    error InvalidAssetAddress();
    error InvalidUsdtAddress();
    error InvalidVaultAddress();
    error InvalidStrategyAddress();
    error StrategyAlreadyExists();
    error InvalidUsdtFeed();
    error InvalidUsdcPriceFeed();
    error InvalidPriceConverter();
    error InvalidPrice();
    error InvalidAgentAddress();
    error InvalidDexRouter();
    error SlippageTooHigh();
    error StrategyNotFound();
    error YearnVaultNotSet();
    error InsufficientIdleAssets();
    error ExcessiveSlippageOnWithdrawal();
    error NoUnfulfilledWithdrawals();
    error NoAvailableAssets();
    error AmountMustBeGreaterThanZero();
    error BridgeDepositAddressNotSet();
    error InsufficientBalance();
    error MaxLossToleranceTooHigh();
    error DuplicateStrategy();
    error CannotRecoverVaultAssets();
    error InvalidRecipient();
    error InsufficientETHBalance();
    error ETHTransferFailed();
    error DexRouterNotConfigured();
    error ExcessiveSlippage();
    error InvalidRouterRegistry();
    error SuperEarnRouterNotSet();
    error PendingOperations(uint256 assetsInTransit);
    error InvalidToken();
    error CustomStrategyAlreadyRegistered(address strategy);
    error CustomStrategyNotRegistered(address strategy);
    error CustomStrategyHasAssets(address strategy, uint256 assets);
    error InvalidDenominationToken(address token);

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Initialize the RemoteVault
     * @param _usdc Address of the USDC token
     * @param _usdt Address of the USDT token
     * @param _owner Owner address for OwnableUpgradeable and GOVERNANCE_ROLE
     */
    function initialize(address _usdc, address _usdt, address _owner) public initializer {
        __ReentrancyGuard_init();
        __SuperEarnAccessControl_init();

        if (_usdt == address(0)) revert InvalidUsdtAddress();
        usdc = _usdc;
        usdt = _usdt;
        usdcDecimals = IERC20MetadataUpgradeable(_usdc).decimals();
        usdtDecimals = IERC20MetadataUpgradeable(_usdt).decimals();

        // Set default slippage (inline initializer not executed in proxy context)
        maxSlippageBps = DEFAULT_MAX_SLIPPAGE_BPS;

        // Grant GOVERNANCE_ROLE to owner
        _grantRole(GOVERNANCE_ROLE, _owner);
    }

    // ============================================
    // Configuration
    // ============================================

    function setYearnVault(address vault, bool isUsdc) external onlyGovernance {
        if (vault == address(0)) revert InvalidVaultAddress();

        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;

        if (yearnVault != address(0) && yearnVault != vault) {
            uint256 shares = IERC20Upgradeable(yearnVault).balanceOf(address(this));
            if (shares != 0) {
                IERC20Upgradeable(yearnVault).safeTransfer(msg.sender, shares);
            }
        }

        // If SuperEarnRouter is configured, validate registry consistency
        if (address(superEarnRouter) != address(0)) {
            address cooldownVault = IVault(vault).token();
            address endorsedVault = superEarnRouter.endorsedVault(cooldownVault);

            // Verify the router's registry points to this vault
            if (endorsedVault != vault) revert InvalidRouterRegistry();
        }

        // Update vault address
        if (isUsdc) usdcYearnVault = vault;
        else usdtYearnVault = vault;

        emit YearnVaultSet(vault, isUsdc);
    }

    /**
     * @notice Set Chainlink price feeds for USDT and USDC
     * @param _usdtPriceFeed Address of USDT/USD price feed
     * @param _usdcPriceFeed Address of USDC/USD price feed
     */
    function setPriceFeeds(address _usdtPriceFeed, address _usdcPriceFeed) external onlyGovernance {
        if (_usdtPriceFeed == address(0)) revert InvalidUsdtFeed();
        if (_usdcPriceFeed == address(0)) revert InvalidUsdcPriceFeed();

        usdtPriceFeed = _usdtPriceFeed;
        usdcPriceFeed = _usdcPriceFeed;

        emit PriceFeedsUpdated(_usdtPriceFeed, _usdcPriceFeed);
    }

    /**
     * @notice Set the price converter contract
     * @param _priceConverter Address of the AssetPriceConverter contract
     */
    function setPriceConverter(address _priceConverter) external onlyGovernance {
        if (_priceConverter == address(0)) revert InvalidPriceConverter();
        priceConverter = AssetPriceConverter(_priceConverter);
        emit PriceConverterUpdated(_priceConverter);
    }

    /**
     * @notice Set swap router for USDT/asset token swaps
     * @param _swapRouter Address of the UniversalSwapRouter contract
     */
    function setSwapRouter(address _swapRouter) external onlyGovernance {
        if (_swapRouter == address(0)) revert InvalidDexRouter();
        swapRouter = UniversalSwapRouter(payable(_swapRouter));
    }

    /**
     * @notice Set SuperEarnRouter for CooldownVault integration
     * @param _router Address of the SuperEarnRouter contract
     * @dev Validates that router's registry matches the configured yearnVault
     */
    function setSuperEarnRouter(address _router) external onlyGovernance {
        if (_router == address(0)) revert InvalidDexRouter();

        // If yearnVault is already configured, validate router's registry
        if (usdcYearnVault != address(0)) {
            address cooldownVault = IVault(usdcYearnVault).token();
            address endorsedVault = SuperEarnRouter(_router).endorsedVault(cooldownVault);

            // Verify the router's registry points to our configured yearnVault
            if (endorsedVault != usdcYearnVault) revert InvalidRouterRegistry();
        }

        if (usdtYearnVault != address(0)) {
            address cooldownVault = IVault(usdtYearnVault).token();
            address endorsedVault = SuperEarnRouter(_router).endorsedVault(cooldownVault);

            // Verify the router's registry points to our configured yearnVault
            if (endorsedVault != usdtYearnVault) revert InvalidRouterRegistry();
        }

        superEarnRouter = SuperEarnRouter(_router);
        emit SuperEarnRouterSet(_router);
    }

    function setMaxSlippage(uint256 _maxSlippageBps) external onlyGovernance {
        if (_maxSlippageBps > BASIS_POINTS) revert SlippageTooHigh();
        maxSlippageBps = _maxSlippageBps;
    }

    /**
     * @notice Set the Runespear agent address
     * @param _agent New agent address
     * @dev Checks for pending bridge operations before allowing replacement
     */
    function setAgent(address _agent) external onlyGovernance {
        if (_agent == address(0)) revert InvalidAgentAddress();

        // Store old agent for event and cleanup
        address oldAgent = address(agent);

        // Check for pending operations if old agent exists
        if (oldAgent != address(0)) {
            uint256 assetsInTransit = agent.getAssetsInTransit();
            if (assetsInTransit > 0) {
                revert PendingOperations(assetsInTransit);
            }
        }

        // Set new agent
        agent = IRunespearAgent(_agent);

        emit AgentUpdated(oldAgent, _agent);
    }

    // ============================================
    // View Functions - Asset Accounting
    // ============================================

    function assetsInTransitToOrigin() public view returns (uint256) {
        if (address(agent) == address(0)) return 0;
        return agent.getAssetsInTransit();
    }

    function totalAssets() public view override(IRemoteVault) returns (uint256) {
        uint256 usdcBalance = IERC20Upgradeable(usdc).balanceOf(address(this));

        uint256 usdtBalance = IERC20Upgradeable(usdt).balanceOf(address(this));
        uint256 usdtAsUsdc = _convertTokenAmount(usdtBalance, usdt, usdc);
        uint256 yearnAssetsInUsdc = _calculateYearnAssets();

        uint256 pendingRedemptions = _calculatePendingCooldownAssets();
        uint256 assetsInTransit = _convertTokenAmount(assetsInTransitToOrigin(), usdt, usdc);
        uint256 customStrategyAssets = _calculateCustomStrategyAssets();
        return
            usdcBalance + usdtAsUsdc + yearnAssetsInUsdc + pendingRedemptions + assetsInTransit + customStrategyAssets;
    }

    function _calculateYearnAssets() internal view returns (uint256) {
        if (address(superEarnRouter) == address(0)) {
            return 0;
        }

        uint256 assetsInUsdc = 0;

        if (usdcYearnVault != address(0)) {
            uint256 ySharesInUsdc = IERC20Upgradeable(usdcYearnVault).balanceOf(address(this));
            assetsInUsdc = superEarnRouter.previewRedeem(usdcYearnVault, ySharesInUsdc);
        }

        if (usdtYearnVault != address(0)) {
            uint256 ySharesInUsdt = IERC20Upgradeable(usdtYearnVault).balanceOf(address(this));
            uint256 assetsInUsdt = superEarnRouter.previewRedeem(usdtYearnVault, ySharesInUsdt);
            assetsInUsdc += _convertTokenAmount(assetsInUsdt, usdt, usdc);
        }

        return assetsInUsdc;
    }

    /**
     * @notice Pending CooldownVault redemption assets owned by this vault.
     * @dev Avoids temporary TVL drop during async withdrawals by including expected claims.
     */
    function _calculatePendingCooldownAssets() internal view returns (uint256) {
        uint256 pendingAssets = 0;

        if (usdcYearnVault != address(0)) {
            ICooldownVault cooldownVault = ICooldownVault(IVault(usdcYearnVault).token());
            pendingAssets = cooldownVault.pendingAssets(address(this));
        }

        if (usdtYearnVault != address(0)) {
            ICooldownVault cooldownVault = ICooldownVault(IVault(usdtYearnVault).token());
            pendingAssets += _convertTokenAmount(cooldownVault.pendingAssets(address(this)), usdt, usdc);
        }

        return pendingAssets;
    }

    /**
     * @notice Calculate total assets in all custom strategies
     * @dev Converts each strategy's totalAssets to base asset using price converter
     * @return total Total assets in base asset units
     */
    function _calculateCustomStrategyAssets() internal view returns (uint256 total) {
        uint256 length = customStrategies.length;
        for (uint256 i = 0; i < length; i++) {
            address strategy = customStrategies[i];
            address denomToken = ICustomStrategy(strategy).denominationToken();
            uint256 strategyTotal = ICustomStrategy(strategy).totalAssets();

            if (strategyTotal == 0) continue;

            // Convert to base asset if strategy uses different denomination token
            if (denomToken != usdc) {
                total += _convertTokenAmount(strategyTotal, denomToken, usdc);
            } else {
                total += strategyTotal;
            }
        }
    }

    function idleUsdc() external view returns (uint256) {
        return IERC20Upgradeable(usdc).balanceOf(address(this));
    }

    function idleUsdt() external view returns (uint256) {
        return IERC20Upgradeable(usdt).balanceOf(address(this));
    }

    function idleAssets() public view returns (uint256) {
        uint256 usdcBal = IERC20Upgradeable(usdc).balanceOf(address(this));
        uint256 usdtBal = IERC20Upgradeable(usdt).balanceOf(address(this));
        return usdcBal + _convertTokenAmount(usdtBal, usdt, usdc);
    }

    function getUnfulfilledWithdrawalInfo() external view returns (uint256 amount) {
        return unfulfilledWithdrawalAmount;
    }

    /**
     * @notice Check if a specific redemption request belongs to this vault and get its details
     * @param requestId The CooldownVault redemption request ID
     * @return isOurs Whether the receiver is this vault
     * @return assets Expected assets amount
     * @return isClaimable Whether cooldown has passed and not yet claimed
     * @dev Helper function for monitoring pending redemptions
     */
    function getRedemptionStatus(
        uint256 requestId,
        bool isUsdc
    )
        external
        view
        returns (bool isOurs, uint256 assets, bool isClaimable)
    {
        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;
        if (yearnVault == address(0)) return (false, 0, false);

        ICooldownVault cooldownVault = ICooldownVault(IVault(yearnVault).token());
        (address receiver, uint256 _assets, uint256 cooldownRequestedTime, uint256 cooldownPeriod, bool claimed) =
            cooldownVault.redeemRequests(requestId);

        isOurs = (receiver == address(this));
        assets = _assets;
        isClaimable = !claimed && block.timestamp >= cooldownRequestedTime + cooldownPeriod;
    }

    /**
     * @notice Calculate how much of the unfulfilled withdrawals can be fulfilled now, in USDT terms
     * @return Amount that can be fulfilled with current available balance
     */
    function fulfillableAmount() public view returns (uint256) {
        if (unfulfilledWithdrawalAmount == 0) {
            return 0;
        }
        uint256 available = IERC20Upgradeable(usdt).balanceOf(address(this));
        return available < unfulfilledWithdrawalAmount ? available : unfulfilledWithdrawalAmount;
    }

    // ============================================
    // Yearn Vault Integration
    // ============================================

    function _withdrawFromYearn(
        uint256 yShares,
        bool isUsdc
    )
        internal
        returns (uint256 cooldownRequestId, uint256 ySharesRedeemed)
    {
        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;
        if (yearnVault == address(0) || yShares == 0) return (0, 0);
        if (address(superEarnRouter) == address(0)) revert SuperEarnRouterNotSet();

        // Check available yVault shares
        uint256 ySharesAvailable = IERC20Upgradeable(yearnVault).balanceOf(address(this));
        if (yShares > ySharesAvailable) {
            yShares = ySharesAvailable; // Redeem all if we don't have enough
        }

        // Calculate expected assets using router's preview (accounts for exchange rates)
        uint256 expectedAssets = superEarnRouter.previewRedeem(yearnVault, yShares);

        // Calculate minimum assets expected (slippage protection)
        uint256 minAssetsOut = (expectedAssets * (BASIS_POINTS - maxSlippageBps)) / BASIS_POINTS;

        // Approve router to spend yVault shares
        IERC20Upgradeable(yearnVault).forceApprove(address(superEarnRouter), yShares);

        // Initiate redemption via router (returns requestId, NOT Asset!)
        // Router will:
        //   1. Withdraw yShares from yVault → get CooldownVault shares
        //   2. Call CooldownVault.redeem() with receiver=address(this)
        //   3. Return requestId
        cooldownRequestId = superEarnRouter.redeem(yearnVault, yShares, address(this), minAssetsOut);
        ySharesRedeemed = ySharesAvailable - IERC20Upgradeable(yearnVault).balanceOf(address(this));

        // Emit event with redemption details
        // NOTE: Asset tokens not received yet! Will be claimed by LightKeeper later
        emit YearnRedemptionInitiated(cooldownRequestId, ySharesRedeemed, expectedAssets, block.timestamp);

        return (cooldownRequestId, ySharesRedeemed);
    }

    function _depositToYearn(uint256 amount, bool isUsdc) internal {
        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;
        if (yearnVault == address(0)) revert YearnVaultNotSet();
        if (address(superEarnRouter) == address(0)) revert SuperEarnRouterNotSet();

        address underlyingAsset = isUsdc ? usdc : usdt;

        // Check current asset token balance first
        uint256 available = IERC20Upgradeable(underlyingAsset).balanceOf(address(this));

        if (amount > available) revert InsufficientIdleAssets();

        // Calculate expected yVault shares from the provided asset amount:
        // 1. asset -> CooldownVault shares
        // 2. CooldownVault shares -> Yearn shares
        uint256 expectedYearnShares = superEarnRouter.previewDeposit(yearnVault, amount);
        if (expectedYearnShares == 0) revert InvalidPrice();

        // Apply slippage protection on the expected Yearn shares
        uint256 minSharesOut = (expectedYearnShares * (BASIS_POINTS - maxSlippageBps)) / BASIS_POINTS;

        // Approve router to spend asset token
        IERC20Upgradeable(underlyingAsset).forceApprove(address(superEarnRouter), amount);

        // Deposit via router: Asset token → CooldownVault → yVault
        uint256 shares = superEarnRouter.deposit(yearnVault, amount, address(this), minSharesOut);

        emit DepositedToYearn(amount, shares);
    }

    // ============================================
    // Lifecycle Keeping Functions for Off-chain Keepers
    // ============================================

    /**
     * @notice Swap USDC to USDT or USDT to USDC via Uniswap V3
     * @dev Called by keeper before fulfilling withdrawals
     * @param isUsdtToUsdc True if swapping USDT to USDC, false if swapping USDC to USDT
     * @param amount Amount of tokens to swap
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @param fee Uniswap V3 pool fee tier (e.g., 100=0.01%, 500=0.05%, 3000=0.3%)
     * @return amountOut Amount of tokens received
     */
    function swapUniswap(
        bool isUsdtToUsdc,
        uint256 amount,
        uint256 minAmountOut,
        uint24 fee
    )
        public
        onlyOperators
        returns (uint256 amountOut)
    {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (address(swapRouter) == address(0)) revert DexRouterNotConfigured();

        address tokenIn = isUsdtToUsdc ? usdt : usdc;
        address tokenOut = isUsdtToUsdc ? usdc : usdt;
        uint256 balance = IERC20Upgradeable(tokenIn).balanceOf(address(this));

        if (balance < amount) revert InsufficientBalance();

        // Get balance before swap for independent verification
        uint256 balanceBefore = IERC20Upgradeable(tokenOut).balanceOf(address(this));

        // Approve router to spend token
        IERC20Upgradeable(tokenIn).forceApprove(address(swapRouter), amount);

        // Execute swap via UniversalSwapRouter (Uniswap V3)
        swapRouter.swapUniswap(tokenIn, tokenOut, amount, minAmountOut, fee);

        // Calculate actual received amount from balance delta (independent verification)
        amountOut = IERC20Upgradeable(tokenOut).balanceOf(address(this)) - balanceBefore;

        // Verify slippage independently of router return value
        if (amountOut < minAmountOut) revert ExcessiveSlippage();

        emit Swapped(tokenIn, tokenOut, amount, amountOut);
        return amountOut;
    }

    /**
     * @notice Swap USDC to USDT or USDT to USDC via Curve
     * @dev Called by keeper before fulfilling withdrawals
     * @param isUsdtToUsdc True if swapping USDT to USDC, false if swapping USDC to USDT
     * @param amount Amount of tokens to swap
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @return amountOut Amount of tokens received
     */
    function swapCurve(
        bool isUsdtToUsdc,
        uint256 amount,
        uint256 minAmountOut
    )
        public
        onlyOperators
        returns (uint256 amountOut)
    {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (address(swapRouter) == address(0)) revert DexRouterNotConfigured();

        address tokenIn = isUsdtToUsdc ? usdt : usdc;
        address tokenOut = isUsdtToUsdc ? usdc : usdt;
        uint256 balance = IERC20Upgradeable(tokenIn).balanceOf(address(this));

        if (balance < amount) revert InsufficientBalance();

        // Get balance before swap for independent verification
        uint256 balanceBefore = IERC20Upgradeable(tokenOut).balanceOf(address(this));

        // Approve router to spend token
        IERC20Upgradeable(tokenIn).forceApprove(address(swapRouter), amount);

        // Execute swap via UniversalSwapRouter (Curve)
        swapRouter.swapCurve(tokenIn, tokenOut, amount, minAmountOut);

        // Calculate actual received amount from balance delta (independent verification)
        amountOut = IERC20Upgradeable(tokenOut).balanceOf(address(this)) - balanceBefore;

        // Verify slippage independently of router return value
        if (amountOut < minAmountOut) revert ExcessiveSlippage();

        emit Swapped(tokenIn, tokenOut, amount, amountOut);
        return amountOut;
    }

    /**
     * @notice Deposit idle assets to Yearn vault (keeper callable)
     * @param amount Amount to deposit (0 means deposit all available)
     * @dev Can be called by owner or keeper
     * @dev Protected against reentrancy during swap operations
     */
    function depositToYearn(uint256 amount, bool isUsdc) external onlyOperators nonReentrant {
        address underlyingAsset = isUsdc ? usdc : usdt;
        uint256 available = IERC20Upgradeable(underlyingAsset).balanceOf(address(this));
        uint256 amountToDeposit = amount == 0 ? available : amount;

        if (amountToDeposit > 0) {
            _depositToYearn(amountToDeposit, isUsdc);
        }
    }

    /**
     * @notice Withdraw from this RemoteVault to Origin
     * @param neededUsdt Amount of USDT requested
     * @return nonce Bridge operation nonce if fulfilled, 0 if unfulfilled
     */
    function handleWithdrawRequest(uint256 neededUsdt)
        external
        override
        onlySystemContract
        nonReentrant
        returns (uint256 nonce)
    {
        uint256 totalAvailableUsdt = IERC20Upgradeable(usdt).balanceOf(address(this));

        // All-or-nothing policy:
        // If the current balance can cover the requested amount, bridge the requested amount right away;
        // otherwise, record it unfulfilled.
        // The subsequent fulfillment will take place by the (off-chain) keeper and/or subsequent on-chain actions.
        if (totalAvailableUsdt >= neededUsdt) {
            return _bridgeAssetsToOrigin(neededUsdt);
        }

        // do NOT automatically request withdrawal from Yearn to let the keeper decide when and how much to withdraw
        // from Yearn
        unfulfilledWithdrawalAmount += neededUsdt;
        emit UnfulfilledWithdrawalIncreased(neededUsdt, unfulfilledWithdrawalAmount);
        return 0;
    }

    /**
     * @dev Keepers should size `yShares` off-chain via superEarnRouter.previewWithdraw()
     */
    function withdrawFromYearn(
        uint256 yShares,
        bool isUsdc
    )
        external
        onlyOperators
        nonReentrant
        returns (uint256 assetAmountOut, uint256 cooldownRequestId, uint256 ySharesRedeemed)
    {
        address underlyingAsset = isUsdc ? usdc : usdt;
        uint256 assetBefore = IERC20Upgradeable(underlyingAsset).balanceOf(address(this));
        (cooldownRequestId, ySharesRedeemed) = _withdrawFromYearn(yShares, isUsdc);
        assetAmountOut = IERC20Upgradeable(underlyingAsset).balanceOf(address(this)) - assetBefore;
    }

    function fulfillPendingWithdrawals() public onlyOperators returns (uint256 fulfilledUsdt) {
        if (unfulfilledWithdrawalAmount == 0) revert NoUnfulfilledWithdrawals();

        fulfilledUsdt = fulfillableAmount();
        if (fulfilledUsdt == 0) revert NoAvailableAssets();

        unfulfilledWithdrawalAmount -= fulfilledUsdt;
        _bridgeAssetsToOrigin(fulfilledUsdt);
        emit UnfulfilledWithdrawalFulfilled(fulfilledUsdt, unfulfilledWithdrawalAmount);
    }

    /**
     * @notice Bridge assets back to Origin (manual emergency operations)
     * @dev Emergency escape hatch for governance to manually bridge assets
     *
     * @param amount Amount of assets to bridge
     * @return nonce The unique nonce for this bridge operation
     */
    function emergencyBridgeAssetsToOrigin(uint256 amount)
        external
        onlyGovernance
        nonReentrant
        returns (uint256 nonce)
    {
        return _bridgeAssetsToOrigin(amount);
    }

    /**
     * @notice Bridge assets back to Origin (internal)
     * @dev This initiates the actual bridge transfer of Asset/USDT back to Origin via agent
     * @param amount Amount of assets to bridge (in Asset terms)
     * @return nonce The unique nonce for this bridge operation
     */
    function _bridgeAssetsToOrigin(uint256 amount) internal returns (uint256 nonce) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        // Note: Remote vault doesn't need to know origin vault address - agent handles routing
        if (address(agent) == address(0)) revert BridgeDepositAddressNotSet();

        address token = usdt;
        uint256 balance = IERC20Upgradeable(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Approve agent to spend tokens (agent handles full custody flow)
        IERC20Upgradeable(token).forceApprove(address(agent), amount);

        // Send via agent (agent orchestrates full flow: vault → agent → adapter → bridge)
        nonce = agent.prepareAndSendAssets(token, amount);

        return nonce;
    }

    /**
     * @notice Emergency withdraw from Yearn vault (manager or governance callable)
     * @param maxLoss Maximum acceptable loss in basis points
     * @dev Can be called by managers
     * @dev Protected against reentrancy during swap operations
     */
    function emergencyWithdrawFromYearn(uint256 maxLoss, bool isUsdc) external onlyManagers nonReentrant {
        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;
        if (yearnVault == address(0)) revert YearnVaultNotSet();
        if (maxLoss > 10_000) revert MaxLossToleranceTooHigh(); // Max 100%

        uint256 shares = IERC20Upgradeable(yearnVault).balanceOf(address(this));
        if (shares > 0) {
            // Withdraw with specified max loss tolerance
            uint256 amount = IVault(yearnVault).withdraw(shares, address(this), maxLoss);

            emit EmergencyWithdrawn(amount);
        }
    }

    // === USDT/Asset Token Conversion Functions ===

    function _convertTokenAmount(
        uint256 tokenInAmount,
        address tokenIn,
        address tokenOut
    )
        internal
        view
        returns (uint256)
    {
        if (tokenInAmount == 0) return 0;
        if (tokenIn == tokenOut) return tokenInAmount;

        if (!(tokenIn == usdt || tokenIn == usdc) || !(tokenOut == usdt || tokenOut == usdc)) {
            revert InvalidToken();
        }

        (uint256 tokenInDecimals, uint256 tokenOutDecimals) =
            tokenIn == usdt ? (usdtDecimals, usdcDecimals) : (usdcDecimals, usdtDecimals);
        (address tokenInPriceFeed, address tokenOutPriceFeed) =
            tokenIn == usdt ? (usdtPriceFeed, usdcPriceFeed) : (usdcPriceFeed, usdtPriceFeed);

        if (tokenInPriceFeed != address(0) && tokenOutPriceFeed != address(0) && address(priceConverter) != address(0))
        {
            return priceConverter.convertTokenAmount(
                tokenInAmount, tokenInPriceFeed, tokenOutPriceFeed, tokenInDecimals, tokenOutDecimals
            );
        }

        return tokenInAmount;
    }

    // === Emergency Functions ===

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Address of the token to recover
     * @param to Address to send the tokens to
     * @param amount Amount of tokens to recover
     */
    function emergencyRecoverToken(address token, address to, uint256 amount) external onlyGovernance {
        if (token == usdc || token == usdt) revert CannotRecoverVaultAssets();
        IERC20Upgradeable(token).safeTransfer(to, amount);
    }

    /**
     * @notice Emergency function to redeem CooldownVault shares
     * @dev Directly calls CooldownVault.redeem() with this vault's shares
     * @return requestId The redemption request ID
     */
    function emergencyCooldownVaultRedeem(bool isUsdc) external onlyGovernance returns (uint256 requestId) {
        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;
        if (yearnVault == address(0)) revert YearnVaultNotSet();

        ICooldownVault cooldownVault = ICooldownVault(IVault(yearnVault).token());
        uint256 shares = IERC20Upgradeable(address(cooldownVault)).balanceOf(address(this));

        if (shares == 0) revert InsufficientBalance();

        // redeem(shares, receiver, owner) - returns requestId (not assets!)
        requestId = cooldownVault.redeem(shares, address(this), address(this));
    }

    /**
     * @notice Emergency function to claim a CooldownVault redemption
     * @param requestId The redemption request ID to claim
     * @param maxLossBps Maximum acceptable loss in basis points
     * @return claimableAssets The amount of assets claimed
     */
    function emergencyCooldownVaultClaim(
        uint256 requestId,
        uint256 maxLossBps,
        bool isUsdc
    )
        external
        onlyGovernance
        returns (uint256 claimableAssets)
    {
        address yearnVault = isUsdc ? usdcYearnVault : usdtYearnVault;
        if (yearnVault == address(0)) revert YearnVaultNotSet();

        ICooldownVault cooldownVault = ICooldownVault(IVault(yearnVault).token());
        claimableAssets = cooldownVault.claim(requestId, maxLossBps);
    }

    // ============================================
    // Custom Strategy Functions
    // ============================================

    /**
     * @notice Add a custom strategy to the vault
     * @dev Strategy must have totalAssets == 0 to be added
     * @param strategy Address of the custom strategy to add
     */
    function addCustomStrategy(address strategy) external onlyGovernance {
        if (strategy == address(0)) revert InvalidStrategyAddress();
        if (isCustomStrategy[strategy]) revert CustomStrategyAlreadyRegistered(strategy);

        // Verify strategy points to this RemoteVault
        if (ICustomStrategy(strategy).remoteVault() != address(this)) {
            revert InvalidStrategyAddress();
        }

        // Verify denomination token is USDC or USDT
        address denomToken = ICustomStrategy(strategy).denominationToken();
        if (denomToken != usdc && denomToken != usdt) {
            revert InvalidDenominationToken(denomToken);
        }

        // Verify strategy has no assets
        uint256 strategyAssets = ICustomStrategy(strategy).totalAssets();
        if (strategyAssets > 0) revert CustomStrategyHasAssets(strategy, strategyAssets);

        // Add to array and mappings
        customStrategies.push(strategy);
        isCustomStrategy[strategy] = true;
        __customStrategyIndex[strategy] = customStrategies.length; // Store index+1

        emit CustomStrategyAdded(strategy);
    }

    /**
     * @notice Remove a custom strategy from the vault
     * @dev Strategy must have totalAssets == 0 to be removed
     * @param strategy Address of the custom strategy to remove
     */
    function removeCustomStrategy(address strategy) external onlyGovernance {
        if (!isCustomStrategy[strategy]) revert CustomStrategyNotRegistered(strategy);

        // Verify strategy has no assets
        // Use try/catch so governance can remove a strategy even if totalAssets() reverts
        try ICustomStrategy(strategy).totalAssets() returns (uint256 strategyAssets) {
            if (strategyAssets > 0) revert CustomStrategyHasAssets(strategy, strategyAssets);
        } catch {
            // Strategy reverted - allow removal so governance can recover
        }

        // Get index (stored as index+1)
        uint256 indexPlusOne = __customStrategyIndex[strategy];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = customStrategies.length - 1;

        // Swap with last element if not already last
        if (index != lastIndex) {
            address lastStrategy = customStrategies[lastIndex];
            customStrategies[index] = lastStrategy;
            __customStrategyIndex[lastStrategy] = indexPlusOne;
        }

        // Remove last element
        customStrategies.pop();
        delete isCustomStrategy[strategy];
        delete __customStrategyIndex[strategy];

        emit CustomStrategyRemoved(strategy);
    }

    /**
     * @notice Deposit tokens to a custom strategy
     * @param strategy Address of the custom strategy
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToCustomStrategy(
        address strategy,
        address token,
        uint256 amount
    )
        external
        onlyOperators
        nonReentrant
    {
        if (!isCustomStrategy[strategy]) revert CustomStrategyNotRegistered(strategy);
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        // Approve and deposit
        IERC20Upgradeable(token).forceApprove(strategy, amount);
        ICustomStrategy(strategy).deposit(token, amount);

        emit DepositedToCustomStrategy(strategy, token, amount);
    }

    /**
     * @notice Withdraw tokens from a custom strategy
     * @param strategy Address of the custom strategy
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @return actual Amount actually withdrawn
     */
    function withdrawFromCustomStrategy(
        address strategy,
        address token,
        uint256 amount
    )
        external
        onlyOperators
        nonReentrant
        returns (uint256 actual)
    {
        if (!isCustomStrategy[strategy]) revert CustomStrategyNotRegistered(strategy);
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        actual = ICustomStrategy(strategy).withdraw(token, amount);

        emit WithdrawnFromCustomStrategy(strategy, token, actual);
    }

    /**
     * @notice Get the number of registered custom strategies
     * @return Number of strategies
     */
    function customStrategyCount() external view returns (uint256) {
        return customStrategies.length;
    }

    /**
     * @notice Get all registered custom strategies
     * @return Array of strategy addresses
     */
    function getCustomStrategies() external view returns (address[] memory) {
        return customStrategies;
    }

    // === ERC165 Support ===
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        // Check AccessControl interface IDs manually to avoid view/pure conflict
        return interfaceId == type(IRemoteVault).interfaceId || interfaceId == type(ICrosschainVault).interfaceId
            || interfaceId == 0x7965db0b // IAccessControl
            || interfaceId == 0x01ffc9a7; // ERC165
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 17 slots (RemoteVault itself, in declaration order)
     *   - yearnVault: 1 slot
     *   - maxSlippageBps: 1 slot
     *   - usdtPriceFeed: 1 slot
     *   - usdcPriceFeed: 1 slot
     *   - priceConverter: 1 slot
     *   - swapRouter: 1 slot
     *   - superEarnRouter: 1 slot
     *   - agent: 1 slot
     *   - usdc: 1 slot
     *   - usdt: 1 slot
     *   - usdcDecimals: 1 slot
     *   - usdtDecimals: 1 slot
     *   - unfulfilledWithdrawalAmount: 1 slot
     *   - usdtYearnVault: 1 slot
     *   - customStrategies: 1 slot (array pointer)
     *   - isCustomStrategy: 1 slot (mapping)
     *   - __customStrategyIndex: 1 slot (mapping)
     *
     * RemoteVault adds: 17 slots
     * Gap = 50 - 17 = 33
     */
    uint256[33] private __gap;
}
