// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IFeedProxy } from "@superearn/external/orakl/IFeedProxy.sol";
import { SuperEarnAccessControl } from "../base/SuperEarnAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title OraklAssetPriceConverter
 * @notice Contract for converting asset prices using Orakl price feeds
 * @dev Previously a library, now a contract to allow configurable price parameters
 */
contract OraklAssetPriceConverter is Initializable, SuperEarnAccessControl {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Custom errors
    error StalePrice(uint256 updatedAt);
    error InvalidPrice();
    error PriceOutOfRange(uint256 price);

    // Configuration parameters (public for transparency)
    uint8 public constant constantDecimals = 8; // Constant decimals for price calculations
    uint256 public maxPriceAge; // Price staleness check in seconds
    uint256 public minStablecoinPrice; // Minimum stablecoin price in 8 decimals
    uint256 public maxStablecoinPrice; // Maximum stablecoin price in 8 decimals

    // Events
    event MaxPriceAgeUpdated(uint256 oldValue, uint256 newValue);
    event MinStablecoinPriceUpdated(uint256 oldValue, uint256 newValue);
    event MaxStablecoinPriceUpdated(uint256 oldValue, uint256 newValue);

    /**
     * @notice Initialize the contract with default values
     * @param _maxPriceAge Maximum age of price data in seconds (default: 5 minutes)
     * @param _minStablecoinPrice Minimum stablecoin price in 8 decimals (default: $0.95)
     * @param _maxStablecoinPrice Maximum stablecoin price in 8 decimals (default: $1.05)
     */
    function initialize(
        uint256 _maxPriceAge,
        uint256 _minStablecoinPrice,
        uint256 _maxStablecoinPrice,
        address _governance
    )
        public
        initializer
    {
        __SuperEarnAccessControl_init();
        maxPriceAge = _maxPriceAge;
        minStablecoinPrice = _minStablecoinPrice;
        maxStablecoinPrice = _maxStablecoinPrice;

        require(_governance != address(0), "Invalid governance address");
        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
    }

    /**
     * @notice Get the latest price data from an Orakl feed proxy
     * @param _feedProxy Address of the Orakl feed proxy
     * @return price The latest price
     * @return feedDecimals The decimals of the price feed
     */
    function getLatestData(address _feedProxy) public view returns (uint256 price, uint8 feedDecimals) {
        (, int256 answer_, uint256 updatedAt) = IFeedProxy(_feedProxy).latestRoundData();
        feedDecimals = IFeedProxy(_feedProxy).decimals();
        if (answer_ <= 0) revert InvalidPrice();
        price = uint256(answer_);
        if (block.timestamp - updatedAt > maxPriceAge) revert StalePrice(updatedAt);
        if (
            price < minStablecoinPrice * (10 ** feedDecimals) / (10 ** constantDecimals)
                || price > maxStablecoinPrice * (10 ** feedDecimals) / (10 ** constantDecimals)
        ) revert PriceOutOfRange(price);

        return (price, feedDecimals);
    }

    /**
     * @notice Get decimals from an Orakl feed proxy
     * @param _feedProxy Address of the Orakl feed proxy
     * @return The decimals of the price feed
     */
    function decimals(address _feedProxy) public view returns (uint8) {
        return IFeedProxy(_feedProxy).decimals();
    }

    // ============================================
    // Configuration Functions (Governance Only)
    // ============================================

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
     * @param _minStablecoinPrice New minimum price in 8 decimals
     */
    function setMinStablecoinPrice(uint256 _minStablecoinPrice) external onlyGovernance {
        uint256 oldValue = minStablecoinPrice;
        minStablecoinPrice = _minStablecoinPrice;
        emit MinStablecoinPriceUpdated(oldValue, _minStablecoinPrice);
    }

    /**
     * @notice Set the maximum stablecoin price threshold
     * @param _maxStablecoinPrice New maximum price in 8 decimals
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
     * Storage usage: 3 slots (maxPriceAge, minStablecoinPrice, maxStablecoinPrice)
     * Gap = 50 - 3 = 47
     */
    uint256[47] private __gap;
}
