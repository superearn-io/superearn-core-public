// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { SuperEarnAccessControl } from "../base/SuperEarnAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title Chainlink Aggregator V3 Interface
 * @notice Interface for Chainlink price feeds
 */
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title AssetPriceConverter
 * @notice Contract for converting between different asset types (USDT, USDC) using Chainlink price feeds
 * @dev Previously a library, now a contract to allow configurable price parameters
 *      Uses USD price feeds for both tokens to calculate conversion rate
 */
contract AssetPriceConverter is Initializable, SuperEarnAccessControl {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Custom errors for better gas efficiency
    error StalePrice();
    error InvalidPrice();
    error PriceFeedNotSet();
    error PriceOutOfRange(uint256 price);

    // Configuration parameters (public for transparency)
    uint256 public constantDecimals; // Constant decimals for price calculations
    uint256 public maxPriceAge; // Maximum age of price data in seconds
    uint256 public minStablecoinPrice; // Minimum stablecoin price in 8 decimals
    uint256 public maxStablecoinPrice; // Maximum stablecoin price in 8 decimals

    // Events
    event ConstantDecimalsUpdated(uint256 oldValue, uint256 newValue);
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event MinStablecoinPriceUpdated(uint256 oldValue, uint256 newValue);
    event MaxStablecoinPriceUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Initialize the contract with default values
     * @param _constantDecimals Expected decimals for Chainlink USD feeds (default: 8)
     * @param _maxPriceAge Maximum age of price data in seconds (default: 24 hours)
     * @param _minStablecoinPrice Minimum stablecoin price in 8 decimals (default: $0.95)
     * @param _maxStablecoinPrice Maximum stablecoin price in 8 decimals (default: $1.05)
     */
    function initialize(
        uint256 _constantDecimals,
        uint256 _maxPriceAge,
        uint256 _minStablecoinPrice,
        uint256 _maxStablecoinPrice,
        address _governance
    )
        public
        initializer
    {
        __SuperEarnAccessControl_init();
        constantDecimals = _constantDecimals;
        maxPriceAge = _maxPriceAge;
        minStablecoinPrice = _minStablecoinPrice;
        maxStablecoinPrice = _maxStablecoinPrice;

        require(_governance != address(0), "Invalid governance address");
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
    }

    /**
     * @notice Get the latest price from a Chainlink feed with comprehensive validation
     * @dev Returns price normalized to constantDecimals to ensure consistent calculations
     *      across different price feeds that may have different native decimals
     * @param priceFeed Address of the Chainlink price feed
     * @return price The latest price normalized to constantDecimals
     */
    function getLatestPrice(address priceFeed) public view returns (uint256 price) {
        if (priceFeed == address(0)) revert PriceFeedNotSet();

        AggregatorV3Interface feed = AggregatorV3Interface(priceFeed);

        // Get feed decimals for normalization
        uint8 feedDecimals = feed.decimals();

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();

        // Check for stale price
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice();

        // Check for invalid price
        if (answer <= 0) revert InvalidPrice();

        // Normalize price to constantDecimals
        // This ensures convertTokenAmount() works correctly even when
        // tokenInPriceFeed and tokenOutPriceFeed have different native decimals
        if (feedDecimals > constantDecimals) {
            price = uint256(answer) / (10 ** (feedDecimals - constantDecimals));
        } else if (feedDecimals < constantDecimals) {
            price = uint256(answer) * (10 ** (constantDecimals - feedDecimals));
        } else {
            price = uint256(answer);
        }

        // Validate price is within reasonable range for stablecoins
        // Protects against oracle manipulation or feed errors
        // Both price and thresholds are now in constantDecimals
        if (price < minStablecoinPrice || price > maxStablecoinPrice) {
            revert PriceOutOfRange(price);
        }

        return price;
    }

    /**
     * @notice Convert token amount from one token to another using price feeds
     * @dev Uses getLatestPrice() which normalizes all prices to constantDecimals,
     *      ensuring correct conversion even when price feeds have different native decimals.
     *      Formula: tokenOutAmount = tokenInAmount * (tokenInPrice / tokenOutPrice) * (10^tokenOutDecimals /
     * 10^tokenInDecimals)
     * @param tokenInAmount Amount of input token
     * @param tokenInPriceFeed Address of input token price feed
     * @param tokenOutPriceFeed Address of output token price feed
     * @param tokenInDecimals Decimals of input token
     * @param tokenOutDecimals Decimals of output token
     * @return tokenOutAmount Amount of output token
     */
    function convertTokenAmount(
        uint256 tokenInAmount,
        address tokenInPriceFeed,
        address tokenOutPriceFeed,
        uint256 tokenInDecimals,
        uint256 tokenOutDecimals
    )
        public
        view
        returns (uint256 tokenOutAmount)
    {
        if (tokenInAmount == 0) return 0;

        // Get prices from Chainlink (normalized to constantDecimals)
        // This ensures correct calculation even if feeds have different native decimals
        uint256 tokenInPrice = getLatestPrice(tokenInPriceFeed);
        uint256 tokenOutPrice = getLatestPrice(tokenOutPriceFeed);

        tokenOutAmount =
            (tokenInAmount * tokenInPrice * (10 ** tokenOutDecimals)) / tokenOutPrice / (10 ** tokenInDecimals);

        return tokenOutAmount;
    }

    // ============================================
    // Configuration Functions (Governance Only)
    // ============================================

    /**
     * @notice Set the constant decimals for price calculations
     * @param _constantDecimals New constant decimals value
     */
    function setConstantDecimals(uint256 _constantDecimals) external onlyGovernance {
        uint256 oldValue = constantDecimals;
        constantDecimals = _constantDecimals;
        emit ConstantDecimalsUpdated(oldValue, _constantDecimals);
    }

    /**
     * @notice Set the maximum price age for staleness checks
     * @param _maxPriceAge New maximum price age in seconds
     */
    function setMaxPriceAge(uint256 _maxPriceAge) external onlyGovernance {
        uint256 oldValue = maxPriceAge;
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeUpdated(oldValue, _maxPriceAge);
    }

    /**
     * @notice Set the minimum stablecoin price threshold
     * @param _minStablecoinPrice New minimum price in configured decimals
     */
    function setMinStablecoinPrice(uint256 _minStablecoinPrice) external onlyGovernance {
        uint256 oldValue = minStablecoinPrice;
        minStablecoinPrice = _minStablecoinPrice;
        emit MinStablecoinPriceUpdated(oldValue, _minStablecoinPrice);
    }

    /**
     * @notice Set the maximum stablecoin price threshold
     * @param _maxStablecoinPrice New maximum price in configured decimals
     */
    function setMaxStablecoinPrice(uint256 _maxStablecoinPrice) external onlyGovernance {
        uint256 oldValue = maxStablecoinPrice;
        maxStablecoinPrice = _maxStablecoinPrice;
        emit MaxStablecoinPriceUpdated(oldValue, _maxStablecoinPrice);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 4 slots (constantDecimals, maxPriceAge, minStablecoinPrice, maxStablecoinPrice)
     * Gap = 50 - 4 = 46
     */
    uint256[46] private __gap;
}
