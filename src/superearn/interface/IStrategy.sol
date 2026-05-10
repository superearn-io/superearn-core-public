// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IVault } from "./IVault.sol";

interface IStrategy {
    // Events
    event Harvested(uint256 profit, uint256 loss, uint256 debtPayment, uint256 debtOutstanding);
    event UpdatedStrategist(address newStrategist);
    event UpdatedKeeper(address newKeeper);
    event UpdatedRewards(address rewards);
    event UpdatedMinReportDelay(uint256 delay);
    event UpdatedMaxReportDelay(uint256 delay);
    event UpdatedBaseFeeOracle(address baseFeeOracle);
    event UpdatedCreditThreshold(uint256 creditThreshold);
    event ForcedHarvestTrigger(bool triggerState);
    event EmergencyExitEnabled();
    event UpdatedMetadataURI(string metadataURI);
    event SetHealthCheck(address);
    event SetDoHealthCheck(bool);

    // Functions
    function name() external view returns (string memory);
    function vault() external view returns (IVault);
    function want() external view returns (IERC20);
    function apiVersion() external pure returns (string memory);
    function strategist() external view returns (address);
    function keeper() external view returns (address);
    function rewards() external view returns (address);
    function emergencyExit() external view returns (bool);
    function minReportDelay() external view returns (uint256);
    function maxReportDelay() external view returns (uint256);
    function baseFeeOracle() external view returns (address);
    function creditThreshold() external view returns (uint256);
    function forceHarvestTriggerOnce() external view returns (bool);
    function metadataURI() external view returns (string memory);
    function doHealthCheck() external view returns (bool);
    function healthCheck() external view returns (address);
    function isActive() external view returns (bool);
    function delegatedAssets() external view returns (uint256);
    function estimatedTotalAssets() external view returns (uint256);
    function tendTrigger(uint256 callCost) external view returns (bool);
    function tend() external;
    function harvestTrigger(uint256 callCost) external view returns (bool);
    function harvest() external;
}
