// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { ICrosschainVault } from "./ICrosschainVault.sol";

/**
 * @title IOriginVault
 * @notice Interface for origin vaults in the crosschain architecture
 * @dev Extends ICrosschainVault with origin-specific operations
 *      Origin vaults:
 *      - Manage user deposits and redemptions
 *      - Coordinate with remote vault for yield generation
 *      - Handle ERC-7540 async redemption flows
 */
interface IOriginVault is ICrosschainVault {
    // ============================================
    // Keeper Functions
    // ============================================

    /**
     * @notice Deposit assets to remote vault
     * @dev Called by keeper to send idle assets to remote for yield generation
     * @param amount Amount of assets to send to remote
     */
    function depositToRemote(uint256 amount) external;

    /**
     * @notice Withdraw assets from remote vault
     * @dev Called by keeper to request assets from remote back to origin
     * @param usdtAmount Amount of USDT to withdraw from remote
     */
    function withdrawFromRemote(uint256 usdtAmount) external;

    /**
     * @notice Process redemption queue (Origin only)
     * @dev Called by keeper to process pending redemptions
     * @param maxAmountUsdt Maximum amount of assets to request from remote
     * @param maxCount Maximum request counts to process
     * @return Amount actually requested from remote
     */
    function processRedemptionQueue(uint256 maxAmountUsdt, uint256 maxCount) external returns (uint256);

    /**
     * @notice Batch fulfill redemptions (Origin only)
     * @dev Called by keeper to fulfill multiple redemptions
     * @param maxAmountUsdt Maximum amount of assets to use for fulfillment
     * @param maxCount Maximum request counts to process
     */
    function batchFulfillRedemptions(uint256 maxAmountUsdt, uint256 maxCount) external;

    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get available idle assets (excluding reserved for redemptions)
     * @dev Used by keeper to determine how much can be bridged to remote
     * @return Amount of idle assets available
     */
    function availableIdleAssets() external view returns (uint256);

    /**
     * @notice Get total assets under management
     * @dev Includes local balance, remote vault assets, and in-transit amounts
     * @return Total assets
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Get assets currently in transit to remote vault
     * @dev Used for monitoring bridge operations
     * @return Amount of assets in transit
     */
    function assetsInTransitToRemote() external view returns (uint256);

    /**
     * @notice Get remote vault assets (with overlap removed)
     * @dev Returns true remote assets reported by the agent
     * @return Amount of assets held in the remote vault (converted to local denomination)
     */
    function remoteAssets() external view returns (uint256);

    /**
     * @notice Get pending redemptions in queue
     * @dev Returns shares and estimated assets for unfulfilled redemptions
     * @return totalShares Total shares pending redemption
     * @return estimatedAssets Estimated assets needed for redemption
     */
    function getPendingRedemptionAmount() external view returns (uint256 totalShares, uint256 estimatedAssets);

    /**
     * @notice Get pending fulfillments in queue
     * @dev Returns shares and estimated assets for requested but unfulfilled redemptions
     * @return totalShares Total shares pending fulfillment
     * @return estimatedAssets Estimated assets needed for fulfillment
     */
    function getPendingFulfillmentAmount() external view returns (uint256 totalShares, uint256 estimatedAssets);

    /**
     * @notice Get redemption queue length
     * @return Number of items in redemption queue
     */
    function getRedemptionQueueLength() external view returns (uint256);
}
