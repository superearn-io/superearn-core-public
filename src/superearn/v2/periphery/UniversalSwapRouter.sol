// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IQuoterV2 } from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { SuperEarnAccessControl } from "../base/SuperEarnAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { ICurvePool } from "../interfaces/ICurvePool.sol";

/// @notice Minimal interface for Uniswap V4 Quoter
interface IV4QuoterMinimal {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/**
 * @title UniversalSwapRouter
 * @notice Router contract for executing token swaps via Uniswap V3 or Curve
 * @dev Provides separate functions for Uniswap and Curve swaps with explicit parameters
 *
 * ## Access Control
 * - Uses SuperEarnAccessControl for consistent governance
 * - GOVERNANCE_ROLE: Can set price feeds, quoters, timelock, and Curve pool configs
 * - Swaps are permissionless (anyone can call with their own tokens)
 * - All addresses are subject to swap timelock (default: 1 hour between swaps)
 */
contract UniversalSwapRouter is Initializable, IUnlockCallback, SuperEarnAccessControl {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Callback data structure for V4 swaps
    struct CallbackData {
        PoolKey key;
        SwapParams params;
        address sender;
    }

    /// @notice Uniswap pool configuration
    /// @dev Stores whether to use V3 or V4 and the V4 PoolKey if applicable
    struct UniswapPoolConfig {
        bool isV4; // true = V4, false = V3
        int24 tickSpacing; // V4 tick spacing (ignored for V3)
        address hooks; // V4 hooks address (ignored for V3)
    }

    ISwapRouter public swapRouter; // for v3
    IPoolManager public poolManager; // for v4
    IQuoterV2 public quoterV2; // for v3 quotes
    // NOTE: v4Quoter occupies slot 204 (previously swapConfigs mapping base slot, always 0x0)
    IV4QuoterMinimal public v4Quoter; // for v4 quotes

    // Chainlink price feed configuration
    mapping(address => address) public priceFeeds; // token => Chainlink price feed address
    uint256 public maxSlippagePercent; // basis points (e.g., 500 = 5%)
    uint256 public constant STALENESS_THRESHOLD = 24 hours;

    // Uniswap V4 price limit constants (from TickMath library)
    /// @dev The minimum value that can be returned from getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 public constant MIN_SQRT_RATIO = 4_295_128_739;
    /// @dev The maximum value that can be returned from getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 public constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    // Swap timelock configuration
    mapping(address => uint256) public lastSwapTimestamp; // user => last swap timestamp
    uint256 public swapTimeLock; // minimum time between swaps (default: 1 hour)

    // Curve pool configuration
    mapping(bytes32 => address) public curvePoolForPair; // tokenPair key => Curve pool address
    mapping(bytes32 => uint16) public curveTokenIndices; // tokenPair key => (tokenInIndex << 8 | tokenOutIndex)

    // Uniswap pool configuration (V3/V4)
    // Key: keccak256(abi.encode(sortedToken0, sortedToken1, fee))
    mapping(bytes32 => UniswapPoolConfig) public uniswapPoolConfigs;

    // === Errors ===
    error AmountMustBeGreaterThanZero();
    error ExcessiveSlippage();
    error InvalidTokenPair();
    error RouterNotConfigured();
    error QuoterNotAvailable();
    error PriceFeedNotSet();
    error ExcessiveSlippageFromPriceFeed();
    error StalePriceFeed();
    error SwapTimeLockNotExpired();
    error InvalidAddress();
    error CurvePoolNotConfigured();
    error InvalidTokenPairForPool();
    error UniswapPoolNotConfigured();
    error InvalidTickSpacing();

    // === Events ===
    event UniswapSwapExecuted(
        address indexed fromToken, address indexed toToken, uint24 fee, uint256 amountIn, uint256 amountOut
    );
    event CurveSwapExecuted(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);
    event PriceFeedSet(address indexed token, address indexed priceFeed);
    event MaxSlippagePercentSet(uint256 maxSlippagePercent);
    event SwapTimeLockSet(uint256 newTimeLock);
    event CurvePoolSet(address indexed tokenIn, address indexed tokenOut, address curvePool);
    event UniswapPoolConfigSet(
        address indexed token0, address indexed token1, uint24 fee, bool isV4, int24 tickSpacing, address hooks
    );

    /**
     * @notice Initialize the UniversalSwapRouter
     * @param _swapRouter SwapRouter contract address for Uniswap V3
     * @param _poolManager PoolManager contract address for Uniswap V4
     * @param _owner Governance address that will receive GOVERNANCE_ROLE
     */
    function initialize(ISwapRouter _swapRouter, IPoolManager _poolManager, address _owner) public initializer {
        __SuperEarnAccessControl_init();

        if (address(_swapRouter) == address(0) || address(_poolManager) == address(0) || _owner == address(0)) {
            revert InvalidAddress();
        }

        swapRouter = _swapRouter;
        poolManager = _poolManager;

        _grantRole(GOVERNANCE_ROLE, _owner);

        // Set default max slippage to 0.25% (25 basis points)
        maxSlippagePercent = 25;

        // Set default swap timelock to 1 hour
        swapTimeLock = 1 hours;
    }

    // ============================================
    // SWAP FUNCTIONS
    // ============================================

    /**
     * @notice Swap tokens using Uniswap (automatically routes to V3 or V4 based on configuration)
     * @dev Pool must be configured via setUniswapPoolConfig before use
     * @param fromToken Token to swap from
     * @param toToken Token to swap to
     * @param amount Amount to swap
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @param fee Uniswap pool fee tier (e.g., 8=0.0008%, 100=0.01%, 500=0.05%, 3000=0.3%, 10000=1%)
     * @return amountOut Amount of tokens received
     */
    function swapUniswap(
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 minAmountOut,
        uint24 fee
    )
        external
        returns (uint256 amountOut)
    {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (fromToken == address(0) || toToken == address(0)) revert InvalidTokenPair();

        // Check timelock
        _checkSwapTimeLock(msg.sender);

        // Check price feeds are set
        if (priceFeeds[fromToken] == address(0) || priceFeeds[toToken] == address(0)) {
            revert PriceFeedNotSet();
        }

        // Get pool configuration
        (address token0, address token1) = _sortTokens(fromToken, toToken);
        bytes32 poolKey = _getUniswapPoolKey(token0, token1, fee);
        UniswapPoolConfig memory config = uniswapPoolConfigs[poolKey];

        // Transfer tokens from sender
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amount);

        // Execute swap based on pool type
        if (config.isV4) {
            amountOut = _swapExactInputSingleUniswapV4(fromToken, toToken, fee, amount, config);
        } else {
            // Default to V3 (for backward compatibility with unconfigured pools)
            amountOut = _swapExactInputSingleUniSwapV3(fromToken, toToken, fee, amount, 0);
        }

        // Check slippage
        if (amountOut < minAmountOut) revert ExcessiveSlippage();

        // Verify slippage using Chainlink price feeds
        _verifySlippageWithPriceFeed(fromToken, toToken, amount, amountOut);

        // Transfer output to sender
        IERC20(toToken).safeTransfer(msg.sender, amountOut);

        // Update last swap timestamp
        lastSwapTimestamp[msg.sender] = block.timestamp;

        emit UniswapSwapExecuted(fromToken, toToken, fee, amount, amountOut);

        return amountOut;
    }

    /**
     * @notice Swap tokens using Curve pool
     * @dev Pool must be configured via setCurvePool before use
     * @param fromToken Token to swap from
     * @param toToken Token to swap to
     * @param amount Amount to swap
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @return amountOut Amount of tokens received
     */
    function swapCurve(
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 minAmountOut
    )
        external
        returns (uint256 amountOut)
    {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (fromToken == address(0) || toToken == address(0)) revert InvalidTokenPair();

        // Check timelock
        _checkSwapTimeLock(msg.sender);

        // Check price feeds are set
        if (priceFeeds[fromToken] == address(0) || priceFeeds[toToken] == address(0)) {
            revert PriceFeedNotSet();
        }

        // Transfer tokens from sender
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amount);

        // Execute swap
        amountOut = _executeCurveSwap(fromToken, toToken, amount);

        // Check slippage
        if (amountOut < minAmountOut) revert ExcessiveSlippage();

        // Verify slippage using Chainlink price feeds
        _verifySlippageWithPriceFeed(fromToken, toToken, amount, amountOut);

        // Transfer output to sender
        IERC20(toToken).safeTransfer(msg.sender, amountOut);

        // Update last swap timestamp
        lastSwapTimestamp[msg.sender] = block.timestamp;

        emit CurveSwapExecuted(fromToken, toToken, amount, amountOut);

        return amountOut;
    }

    // ============================================
    // QUOTE FUNCTIONS (Public)
    // ============================================

    /**
     * @notice Get quote for Uniswap swap (automatically routes to V3 or V4 quoter based on configuration)
     * @param fromToken Token to swap from
     * @param toToken Token to swap to
     * @param amount Amount to swap
     * @param fee Uniswap pool fee tier
     * @return amountOut Estimated amount out
     */
    function quoteUniswap(
        address fromToken,
        address toToken,
        uint256 amount,
        uint24 fee
    )
        external
        returns (uint256 amountOut)
    {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        // Get pool configuration
        (address token0, address token1) = _sortTokens(fromToken, toToken);
        bytes32 poolKey = _getUniswapPoolKey(token0, token1, fee);
        UniswapPoolConfig memory config = uniswapPoolConfigs[poolKey];

        if (config.isV4) {
            return _quoteUniswapV4Single(fromToken, toToken, fee, amount, config);
        } else {
            return _quoteUniswapV3Single(fromToken, toToken, fee, amount);
        }
    }

    /**
     * @notice Get quote for Curve swap
     * @param fromToken Token to swap from
     * @param toToken Token to swap to
     * @param amount Amount to swap
     * @return amountOut Estimated amount out
     */
    function quoteCurve(address fromToken, address toToken, uint256 amount) external view returns (uint256 amountOut) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        return _quoteCurveSingle(fromToken, toToken, amount);
    }

    // ============================================
    // CONFIGURATION FUNCTIONS
    // ============================================

    /**
     * @notice Set Uniswap V3 and V4 quoter addresses
     * @param _quoterV2 Uniswap V3 QuoterV2 address
     * @param _v4Quoter Uniswap V4 Quoter address
     */
    function setQuoters(address _quoterV2, address _v4Quoter) external onlyGovernance {
        quoterV2 = IQuoterV2(_quoterV2);
        v4Quoter = IV4QuoterMinimal(_v4Quoter);
    }

    /**
     * @notice Set Chainlink price feed for a token
     * @param token Token address
     * @param priceFeed Chainlink price feed address
     */
    function setPriceFeed(address token, address priceFeed) external onlyGovernance {
        priceFeeds[token] = priceFeed;
        emit PriceFeedSet(token, priceFeed);
    }

    /**
     * @notice Set maximum allowed slippage percentage
     * @param _maxSlippagePercent Maximum slippage in basis points (e.g., 500 = 5%)
     */
    function setMaxSlippagePercent(uint256 _maxSlippagePercent) external onlyGovernance {
        maxSlippagePercent = _maxSlippagePercent;
        emit MaxSlippagePercentSet(_maxSlippagePercent);
    }

    /**
     * @notice Set swap timelock duration
     * @param _swapTimeLock Minimum time between swaps in seconds
     */
    function setSwapTimeLock(uint256 _swapTimeLock) external onlyGovernance {
        swapTimeLock = _swapTimeLock;
        emit SwapTimeLockSet(_swapTimeLock);
    }

    /**
     * @notice Configure Curve pool for a token pair
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param curvePool Curve pool contract address
     * @param tokenInIndex Index of input token in the Curve pool
     * @param tokenOutIndex Index of output token in the Curve pool
     */
    function setCurvePool(
        address tokenIn,
        address tokenOut,
        address curvePool,
        int128 tokenInIndex,
        int128 tokenOutIndex
    )
        external
        onlyManagers
    {
        if (tokenIn == address(0) || tokenOut == address(0) || curvePool == address(0)) {
            revert InvalidAddress();
        }

        // Set forward direction (tokenIn -> tokenOut)
        bytes32 forwardKey = keccak256(abi.encode(tokenIn, tokenOut));
        curvePoolForPair[forwardKey] = curvePool;
        curveTokenIndices[forwardKey] = uint16(uint128(tokenInIndex) << 8 | uint128(tokenOutIndex));

        // Set reverse direction (tokenOut -> tokenIn)
        bytes32 reverseKey = keccak256(abi.encode(tokenOut, tokenIn));
        curvePoolForPair[reverseKey] = curvePool;
        curveTokenIndices[reverseKey] = uint16(uint128(tokenOutIndex) << 8 | uint128(tokenInIndex));

        emit CurvePoolSet(tokenIn, tokenOut, curvePool);
    }

    /**
     * @notice Configure Uniswap pool (V3 or V4) for a token pair and fee tier
     * @dev Token order doesn't matter - internally sorted for consistent key generation
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param fee Pool fee tier
     * @param isV4 True for V4 pool, false for V3 pool
     * @param tickSpacing V4 tick spacing (ignored for V3, set to 0)
     * @param hooks V4 hooks address (ignored for V3, set to address(0))
     */
    function setUniswapPoolConfig(
        address tokenA,
        address tokenB,
        uint24 fee,
        bool isV4,
        int24 tickSpacing,
        address hooks
    )
        external
        onlyManagers
    {
        if (tokenA == address(0) || tokenB == address(0)) {
            revert InvalidAddress();
        }
        if (tokenA == tokenB) {
            revert InvalidTokenPair();
        }
        if (isV4 && tickSpacing <= 0) {
            revert InvalidTickSpacing();
        }

        // Sort tokens for consistent key generation
        (address token0, address token1) = _sortTokens(tokenA, tokenB);

        bytes32 poolKey = _getUniswapPoolKey(token0, token1, fee);

        uniswapPoolConfigs[poolKey] = UniswapPoolConfig({ isV4: isV4, tickSpacing: tickSpacing, hooks: hooks });

        emit UniswapPoolConfigSet(token0, token1, fee, isV4, tickSpacing, hooks);
    }

    /**
     * @notice Remove Uniswap pool configuration
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param fee Pool fee tier
     */
    function removeUniswapPoolConfig(address tokenA, address tokenB, uint24 fee) external onlyManagers {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 poolKey = _getUniswapPoolKey(token0, token1, fee);

        delete uniswapPoolConfigs[poolKey];

        emit UniswapPoolConfigSet(token0, token1, fee, false, 0, address(0));
    }

    /**
     * @notice Get Uniswap pool configuration for a token pair and fee
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param fee Pool fee tier
     * @return config The pool configuration
     */
    function getUniswapPoolConfig(
        address tokenA,
        address tokenB,
        uint24 fee
    )
        external
        view
        returns (UniswapPoolConfig memory config)
    {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 poolKey = _getUniswapPoolKey(token0, token1, fee);
        return uniswapPoolConfigs[poolKey];
    }

    // ============================================
    // INTERNAL HELPER FUNCTIONS
    // ============================================

    /**
     * @notice Sort two token addresses (smaller address first)
     * @param tokenA First token
     * @param tokenB Second token
     * @return token0 Smaller address
     * @return token1 Larger address
     */
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /**
     * @notice Generate a unique key for Uniswap pool lookup
     * @dev Tokens must be pre-sorted
     * @param token0 Smaller token address
     * @param token1 Larger token address
     * @param fee Pool fee tier
     * @return Unique pool key
     */
    function _getUniswapPoolKey(address token0, address token1, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1, fee));
    }

    /**
     * @notice Build V4 PoolKey from tokens and config
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param fee Pool fee tier
     * @param config Pool configuration
     * @return poolKey The V4 PoolKey
     * @return zeroForOne True if swapping token0 for token1
     */
    function _buildV4PoolKey(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        UniswapPoolConfig memory config
    )
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        (address token0, address token1) = _sortTokens(tokenIn, tokenOut);
        zeroForOne = tokenIn == token0;

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hooks)
        });
    }

    // ============================================
    // INTERNAL SWAP FUNCTIONS
    // ============================================

    /**
     * @notice Execute Uniswap V3 single swap
     */
    function _swapExactInputSingleUniSwapV3(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum
    )
        internal
        returns (uint256 amountOut)
    {
        // Approve token
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        // V3 swap parameters
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        // Interact with individual pool contract
        amountOut = swapRouter.exactInputSingle(params);
    }

    /**
     * @notice Execute Uniswap V4 single swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param fee Pool fee tier
     * @param amountIn Amount of input token to swap
     * @param config Pool configuration containing V4 parameters
     * @return amountOut Amount of output token received
     */
    function _swapExactInputSingleUniswapV4(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        UniswapPoolConfig memory config
    )
        internal
        returns (uint256 amountOut)
    {
        // Build V4 PoolKey
        (PoolKey memory poolKey, bool zeroForOne) = _buildV4PoolKey(tokenIn, tokenOut, fee, config);

        // Build swap params (negative = exact input)
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
        });

        // Encode callback data
        CallbackData memory callbackData = CallbackData({ key: poolKey, params: swapParams, sender: address(this) });

        // Get balance before swap
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap via unlock callback
        poolManager.unlock(abi.encode(callbackData));

        // Calculate amount out from balance delta
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
    }

    /**
     * @notice Execute a Curve swap with automatic pool and index lookup
     * @dev Uses balance delta measurement for legacy Curve pools that don't return values
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of input token to swap
     * @return amountOut Amount of output token received
     */
    function _executeCurveSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        internal
        returns (uint256 amountOut)
    {
        bytes32 pairKey = keccak256(abi.encode(tokenIn, tokenOut));
        address curvePool = curvePoolForPair[pairKey];
        if (curvePool == address(0)) revert CurvePoolNotConfigured();

        uint16 indices = curveTokenIndices[pairKey];
        int128 tokenInIdx = int128(uint128(indices >> 8));
        int128 tokenOutIdx = int128(uint128(indices & 0xFF));

        // Approve Curve pool to spend input token
        IERC20(tokenIn).forceApprove(curvePool, amountIn);

        // Get balance before swap (legacy Curve pools don't return values)
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap on Curve pool (no return value for legacy pools)
        ICurvePool(curvePool).exchange(tokenInIdx, tokenOutIdx, amountIn, 0);

        // Calculate amount out from balance delta
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
    }

    // ============================================
    // UNISWAP V4 CALLBACK (kept for future use)
    // ============================================

    // V4 callback function
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager can call");
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Execute swap
        BalanceDelta delta = poolManager.swap(callbackData.key, callbackData.params, "");
        // Settle tokens
        _settleDeltas(callbackData.key, delta, callbackData.sender);
        return abi.encode(delta);
    }

    // Helper function: Extract address from Currency
    function _getCurrencyAddress(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }

    // Helper function: Settle deltas
    function _settleDeltas(PoolKey memory key, BalanceDelta delta, address sender) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle currency0
        if (delta0 < 0) {
            // Debt: settle (pay)
            _settle(key.currency0, sender, uint256(uint128(-delta0)));
        } else if (delta0 > 0) {
            // Credit: take (receive)
            _take(key.currency0, sender, uint256(uint128(delta0)));
        }
        // Settle currency1
        if (delta1 < 0) {
            // Debt: settle (pay)
            _settle(key.currency1, sender, uint256(uint128(-delta1)));
        } else if (delta1 > 0) {
            // Credit: take (receive)
            _take(key.currency1, sender, uint256(uint128(delta1)));
        }
    }

    // Helper function: Token settlement (debt payment)
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{ value: amount }();
        } else {
            // Call sync() first to save current balance as checkpoint
            poolManager.sync(currency);

            if (payer != address(this)) {
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
            } else {
                address token = Currency.unwrap(currency);
                SafeERC20.safeTransfer(IERC20(token), address(poolManager), amount);
            }

            // Call settle() to update delta
            poolManager.settle();
        }
    }

    // Helper function: Token receipt (credit collection)
    function _take(Currency currency, address recipient, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // For native ETH
            poolManager.take(currency, recipient, amount);
        } else {
            // For ERC20 tokens (including USDT)
            // Take to this contract first
            poolManager.take(currency, address(this), amount);

            if (recipient != address(this)) {
                // Transfer using SafeERC20 for safe token transfers (handles USDT compatibility)
                address token = Currency.unwrap(currency);
                IERC20(token).safeTransfer(recipient, amount);
            }
        }
    }

    // ============================================
    // INTERNAL VALIDATION FUNCTIONS
    // ============================================

    /**
     * @notice Verify slippage using Chainlink price feeds
     * @param fromToken Token swapped from
     * @param toToken Token swapped to
     * @param amountIn Amount of fromToken spent
     * @param amountOut Amount of toToken received
     */
    function _verifySlippageWithPriceFeed(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 amountOut
    )
        internal
        view
    {
        // Get price feeds
        AggregatorV3Interface fromFeed = AggregatorV3Interface(priceFeeds[fromToken]);
        AggregatorV3Interface toFeed = AggregatorV3Interface(priceFeeds[toToken]);

        // Get latest prices with timestamps
        (, int256 fromPrice,, uint256 fromUpdatedAt,) = fromFeed.latestRoundData();
        (, int256 toPrice,, uint256 toUpdatedAt,) = toFeed.latestRoundData();

        require(fromPrice > 0 && toPrice > 0, "Invalid price data");

        // Check staleness (24 hours)
        if (block.timestamp - fromUpdatedAt > STALENESS_THRESHOLD) {
            revert StalePriceFeed();
        }
        if (block.timestamp - toUpdatedAt > STALENESS_THRESHOLD) {
            revert StalePriceFeed();
        }

        // Calculate expected amountOut based on Chainlink prices
        // expectedAmountOut = amountIn * fromPrice / toPrice (adjusted for decimals)
        uint256 expectedOut;
        {
            uint256 numerator =
                amountIn * uint256(fromPrice) * (10 ** IERC20Metadata(toToken).decimals()) * (10 ** toFeed.decimals());
            uint256 denominator =
                uint256(toPrice) * (10 ** IERC20Metadata(fromToken).decimals()) * (10 ** fromFeed.decimals());
            expectedOut = numerator / denominator;
        }

        // Calculate minimum acceptable amountOut considering max slippage
        uint256 minAcceptable = (expectedOut * (10_000 - maxSlippagePercent)) / 10_000;

        // Revert if actual amountOut is less than minimum acceptable (user got less than expected)
        if (amountOut < minAcceptable) {
            revert ExcessiveSlippageFromPriceFeed();
        }
    }

    /**
     * @notice Check if swap timelock has expired for the user
     * @param user Address of the user attempting to swap
     */
    function _checkSwapTimeLock(address user) internal view {
        uint256 lastSwap = lastSwapTimestamp[user];

        // If this is the first swap, allow it
        if (lastSwap == 0) {
            return;
        }

        uint256 timeSinceLastSwap = block.timestamp - lastSwap;

        // Revert if timelock has not expired
        if (timeSinceLastSwap < swapTimeLock) {
            revert SwapTimeLockNotExpired();
        }
    }

    // ============================================
    // INTERNAL QUOTE FUNCTIONS
    // ============================================

    /**
     * @notice Get quote for Uniswap V3 single swap
     * @param tokenIn Token to swap from
     * @param tokenOut Token to swap to
     * @param fee Pool fee tier
     * @param amountIn Amount to swap
     * @return amountOut Estimated amount out
     */
    function _quoteUniswapV3Single(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    )
        internal
        returns (uint256 amountOut)
    {
        if (address(quoterV2) == address(0)) revert QuoterNotAvailable();

        try quoterV2.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                amountIn: amountIn,
                sqrtPriceLimitX96: 0
            })
        ) returns (
            uint256 _amountOut,
            uint160, // sqrtPriceX96After
            uint32, // initializedTicksCrossed
            uint256
        ) {
            amountOut = _amountOut;
        } catch {
            // If quote fails, return 0
            amountOut = 0;
        }
    }

    /**
     * @notice Get quote for Uniswap V4 single swap
     * @param tokenIn Token to swap from
     * @param tokenOut Token to swap to
     * @param fee Pool fee tier
     * @param amountIn Amount to swap
     * @param config Pool configuration
     * @return amountOut Estimated amount out
     */
    function _quoteUniswapV4Single(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        UniswapPoolConfig memory config
    )
        internal
        returns (uint256 amountOut)
    {
        if (address(v4Quoter) == address(0)) revert QuoterNotAvailable();

        // Build V4 PoolKey
        (PoolKey memory poolKey, bool zeroForOne) = _buildV4PoolKey(tokenIn, tokenOut, fee, config);

        try v4Quoter.quoteExactInputSingle(
            IV4QuoterMinimal.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: uint128(amountIn),
                hookData: ""
            })
        ) returns (uint256 _amountOut, uint256) {
            amountOut = _amountOut;
        } catch {
            // If quote fails, return 0
            amountOut = 0;
        }
    }

    /**
     * @notice Get quote for Curve single swap
     * @param tokenIn Token to swap from
     * @param tokenOut Token to swap to
     * @param amountIn Amount to swap
     * @return amountOut Estimated amount out
     */
    function _quoteCurveSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        internal
        view
        returns (uint256 amountOut)
    {
        bytes32 pairKey = keccak256(abi.encode(tokenIn, tokenOut));
        address curvePool = curvePoolForPair[pairKey];
        if (curvePool == address(0)) revert CurvePoolNotConfigured();

        uint16 indices = curveTokenIndices[pairKey];
        int128 tokenInIdx = int128(uint128(indices >> 8));
        int128 tokenOutIdx = int128(uint128(indices & 0xFF));

        try ICurvePool(curvePool).get_dy(tokenInIdx, tokenOutIdx, amountIn) returns (uint256 _amountOut) {
            amountOut = _amountOut;
        } catch {
            // If quote fails, return 0
            amountOut = 0;
        }
    }

    /**
     * @notice Receive function to accept native tokens (ETH)
     * @dev Allows the contract to receive native tokens for use in swaps or other operations
     */
    receive() external payable { }

    /**
     * @dev Storage gap for upgradeability
     *
     * Storage usage: 12 slots
     *   - swapRouter: 1 slot
     *   - poolManager: 1 slot
     *   - quoterV2: 1 slot
     *   - v4Quoter: 1 slot
     *   - priceFeeds (mapping pointer): 1 slot
     *   - maxSlippagePercent: 1 slot
     *   - lastSwapTimestamp (mapping pointer): 1 slot
     *   - swapTimeLock: 1 slot
     *   - curvePoolForPair (mapping pointer): 1 slot
     *   - curveTokenIndices (mapping pointer): 1 slot
     *   - uniswapPoolConfigs (mapping pointer): 1 slot
     * Gap = 50 - 12 = 38
     */
    uint256[38] private __gap;
}
