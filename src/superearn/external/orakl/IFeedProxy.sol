// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IFeed } from "./IFeed.sol";

/**
 * @dev Minimal Orakl feed proxy interface replicated locally to avoid package.exports restrictions.
 * Source: bisonai/orakl-contracts v0.2 (MIT)
 */
interface IFeedProxy is IFeed {
    function getRoundDataFromProposedFeed(uint64 roundId)
        external
        view
        returns (uint64 id, int256 answer, uint256 updatedAt);

    function latestRoundDataFromProposedFeed() external view returns (uint64 id, int256 answer, uint256 updatedAt);

    function getFeed() external view returns (address);

    function getProposedFeed() external view returns (address);

    function twapFromProposedFeed(uint256 interval, uint256 latestUpdatedAtTolerance, int256 minCount)
        external
        view
        returns (int256);
}
