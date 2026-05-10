// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Minimal Orakl feed interface replicated locally to avoid package.exports restrictions.
 * Source: bisonai/orakl-contracts v0.2 (MIT)
 */
interface IFeed {
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);

    function typeAndVersion() external view returns (string memory);

    function latestRoundData() external view returns (uint64 id, int256 answer, uint256 updatedAt);

    function latestRoundUpdatedAt() external view returns (uint256);

    function twap(uint256 interval, uint256 latestUpdatedAtTolerance, int256 minCount) external view returns (int256);

    function getRoundData(uint64 roundId) external view returns (uint64 id, int256 answer, uint256 updatedAt);
}
