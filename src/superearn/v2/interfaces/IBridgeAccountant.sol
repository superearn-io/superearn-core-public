// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { SuperEarnV2Protocol } from "../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../messaging/runespear/RunespearProtocol.sol";
import { BridgeQueue } from "../core/crosschain/BridgeQueue.sol";

/**
 * @title IBridgeAccountant
 * @notice Interface for bridge accounting and tracking
 * @dev Separates bridge accounting logic from CrosschainAdapter infrastructure
 *
 * ## Architectural Role
 *
 * BridgeAccountant is the **accounting layer** for crosschain bridge operations:
 * - CrosschainAdapter = Infrastructure (bridge callbacks, message routing, asset handling)
 * - BridgeAccountant = Accounting (tracking, calculations, reconciliation, overlap logic)
 *
 * ## Responsibilities
 *
 * 1. **State Tracking:**
 *    - Outbound operations (sent to peer, awaiting confirmation)
 *    - Inbound operations (received from peer, awaiting peer release)
 *    - Pending notifications (SYNC_BRIDGED messages awaiting asset arrival)
 *    - Peer state snapshots (for overlap calculations)
 *
 * 2. **Overlap Calculations:**
 *    - Prevent double-counting when assets are in-transit
 *    - Calculate true peer assets (reported minus overlap)
 *    - Calculate true outbound in-transit (outbound minus confirmed)
 *
 * 3. **Reconciliation:**
 *    - Confirm outbound operations when peer reports receipt
 *    - Acknowledge inbound operations when peer confirms
 *    - Maintain consistency between both chains' view of bridge state
 *
 * ## Access Control
 *
 * - Only the configured CrosschainAdapter can call state-modifying functions
 * - View functions are public for transparency and monitoring
 */
interface IBridgeAccountant {
    // ============================================
    // Events
    // ============================================

    event AdapterSet(address indexed adapter);
    event OutboundRecorded(uint256 indexed nonce, uint256 amount, uint256 timestamp);
    event InboundRecorded(uint256 indexed nonce, uint256 amount, uint256 timestamp);
    event PeerSnapshotUpdated(uint256 timestamp, uint256 peerAssets);
    event BridgeStateReconciled(
        uint256 indexed sourceChainId, uint256 outboundReceivedByPeerCount, uint256 inboundReleasedByPeerCount
    );
    event OutboundNonceUpdated(uint256 previousNonce, uint256 newNonce);

    // ============================================
    // Errors
    // ============================================

    error OnlyAdapter();
    error InvalidAdapter();

    // ============================================
    // Configuration
    // ============================================

    /**
     * @notice Get the configured adapter address
     * @return Address of the CrosschainAdapter
     */
    function adapter() external view returns (address);

    /**
     * @notice Set the adapter address (owner only)
     * @param _adapter New adapter address
     */
    function setAdapter(address _adapter) external;

    // ============================================
    // State Recording (Adapter → Accountant)
    // ============================================

    /**
     * @notice Allocate and record a new outbound bridge operation
     * @dev Generates the next nonce and records the outbound amount atomically
     * @param amount Amount of assets being bridged
     * @return nonce Newly allocated outbound nonce
     */
    function allocateOutboundNonce(uint256 amount) external returns (uint256 nonce);

    /**
     * @notice Record an outbound bridge operation
     * @dev Called by adapter when sending assets to peer using an externally supplied nonce
     * @param nonce Unique nonce for this operation
     * @param amount Amount of assets being sent
     */
    function recordOutbound(uint256 nonce, uint256 amount) external;

    /**
     * @notice Record an inbound bridge operation
     * @dev Called by adapter when receiving assets from peer
     * @param nonce Unique nonce from sender (peer)
     * @param amount Amount of assets received
     * @param sentAt When the bridge was initiated on source chain (from Bridged.timestamp)
     */
    function recordInbound(uint256 nonce, uint256 amount, uint256 sentAt) external;

    /**
     * @notice Add a pending bridge notification
     * @dev Called when SYNC_BRIDGED message arrives but assets haven't arrived yet
     * @param notification Bridge notification from peer
     */
    function addAwaitingAssetNotification(RunespearProtocol.Bridged memory notification) external;

    /**
     * @notice Remove a awaiting-asset notification
     * @dev Called after successfully processing a notification
     * @param nonce The nonce to remove
     */
    function removeAwaitingAssetNotification(uint256 nonce) external;

    /**
     * @notice Update peer state snapshot
     * @dev Called on every message received from peer
     * @param snapshot Complete state snapshot from peer (vault state + bridge state)
     */
    function updatePeerSnapshot(SuperEarnV2Protocol.StateSnapshot memory snapshot) external;

    /**
     * @notice Reconcile bridge operations using peer's reported state
     * @dev Called on every message received from peer
     * @param sourceChainId Chain ID of the peer
     * @param peerBridgeState The peer's piggybacked bridge state
     * @return result Arrays of outbound nonces marked received and inbound nonces marked released
     */
    function reconcileBridgeState(
        uint256 sourceChainId,
        RunespearProtocol.BridgeState memory peerBridgeState
    )
        external
        returns (BridgeQueue.ReconciliationResult memory result);

    // ============================================
    // View Functions - Calculations
    // ============================================

    /**
     * @notice Calculate true outbound in-transit (with overlap removed)
     * @dev Used by vault for totalAssets calculation
     * @return Amount of assets in-transit to peer (not yet confirmed)
     */
    function calculateTrueOutboundInTransit() external view returns (uint256);

    /**
     * @notice Calculate inbound overlap amount
     * @dev Used to prevent double-counting when peer's totalAssets includes assets we already received
     * @return Overlap amount to subtract from peer's reported assets
     */
    function calculateInboundOverlap() external view returns (uint256);

    /**
     * @notice Calculate true peer assets (reported minus overlap)
     * @dev Used by vault for remoteAssets() calculation
     * @return assets True peer assets (overlap-adjusted)
     * @return assetType Asset denomination reported by peer
     */
    function calculateTruePeerAssets()
        external
        view
        returns (uint256 assets, SuperEarnV2Protocol.AssetType assetType);

    /**
     * @notice Get peer's reported total assets (from snapshot)
     * @return Peer's last reported totalAssets
     */
    function getPeerReportedAssets() external view returns (uint256);

    /**
     * @notice Get peer snapshot timestamp
     * @return Timestamp of last peer snapshot update
     */
    function getPeerTimestamp() external view returns (uint256);

    /**
     * @notice Get current bridge state
     * @return BridgeState struct with current outbound/inbound tracking
     */
    function getCurrentBridgeState() external view returns (RunespearProtocol.BridgeState memory);

    /**
     * @notice Get the latest allocated outbound nonce
     * @return Highest outbound nonce assigned so far
     */
    function getCurrentOutboundNonce() external view returns (uint256);

    /**
     * @notice Check if an inbound operation has been recorded
     * @param nonce Nonce to inspect
     * @return True if the inbound operation exists (regardless of release state)
     */
    function isInboundRecorded(uint256 nonce) external view returns (bool);

    /**
     * @notice Check if an inbound operation is awaiting peer release
     * @param nonce Nonce to inspect
     * @return True if the inbound operation exists and awaits peer release
     */
    function isInboundAwaitingPeerRelease(uint256 nonce) external view returns (bool);

    // ============================================
    // View Functions - State Queries
    // ============================================

    /**
     * @notice Get total assets in outbound transit (before overlap adjustment)
     * @return Raw total of outbound operations
     */
    function assetsInTransitOutbound() external view returns (uint256);

    /**
     * @notice Get total assets in inbound transit (before peer release)
     * @return Raw total of inbound operations
     */
    function assetsInTransitInbound() external view returns (uint256);

    /**
     * @notice Get outbound nonces awaiting peer receipt
     * @return Array of outbound nonces awaiting peer receipt
     */
    function getOutboundAwaitingPeerReceiptNonces() external view returns (uint256[] memory);

    /**
     * @notice Get inbound nonces awaiting peer release
     * @return Array of inbound nonces awaiting peer release
     */
    function getInboundAwaitingPeerReleaseNonces() external view returns (uint256[] memory);

    /**
     * @notice Get bridge notification nonces awaiting asset delivery
     * @return Array of nonces with SYNC_BRIDGED notifications awaiting assets
     */
    function getAwaitingAssetNonces() external view returns (uint256[] memory);

    /**
     * @notice Get an awaiting-asset notification
     * @param nonce The nonce to look up
     * @return exists Whether notification exists
     * @return notification The notification (empty if doesn't exist)
     */
    function getAwaitingAssetNotification(uint256 nonce)
        external
        view
        returns (bool exists, RunespearProtocol.Bridged memory notification);

    /**
     * @notice Get count of bridge notifications awaiting assets
     * @return Number of notifications still waiting on assets
     */
    function getAwaitingAssetCount() external view returns (uint256);

    // ============================================
    // View Functions - Debug/Monitoring
    // ============================================

    /**
     * @notice Get peer's outbound nonces from snapshot
     * @return Array of peer's outbound nonces at snapshot time
     */
    function getPeerSnapshotOutboundNonces() external view returns (uint256[] memory);

    /**
     * @notice Get inbound received but pending nonces
     * @return Array of nonces we've received but awaiting peer release
     */
    function getInboundReceivedPendingNonces() external view returns (uint256[] memory);

    // ============================================
    // Admin Functions
    // ============================================

    /**
     * @notice Set timeout for bridge operations
     * @param newTimeout New timeout duration in seconds
     */
    function setBridgeTimeout(uint256 newTimeout) external;
    /**
     * @notice Set the current outbound nonce pointer
     * @dev Governance utility for adapter migrations; must not decrease existing nonce
     * @param newNonce New outbound nonce value
     */
    function forceSetOutboundNonce(uint256 newNonce) external;

    /**
     * @notice Manually clear an outbound operation by nonce
     * @param nonce The nonce to clear
     */
    function forceManualClearOutboundByNonce(uint256 nonce) external;

    /**
     * @notice Manually clear outbound operations by amount
     * @param amount Amount to clear
     */
    function forceManualClearOutboundByAmount(uint256 amount) external;

    /**
     * @notice Clear expired outbound operations
     * @return clearedCount Number of operations cleared
     * @return clearedAmount Total amount cleared
     */
    function clearExpiredOutboundAwaitingPeerReceipt() external returns (uint256 clearedCount, uint256 clearedAmount);

    /**
     * @notice Manually clear an inbound operation by nonce
     * @param nonce The nonce to clear
     */
    function forceManualReleaseInboundByNonce(uint256 nonce) external;

    /**
     * @notice Manually clear inbound operations by amount
     * @param amount Amount to clear
     */
    function forceManualReleaseInboundByAmount(uint256 amount) external;

    /**
     * @notice Clear expired inbound operations
     * @return clearedCount Number of operations cleared
     * @return clearedAmount Total amount cleared
     */
    function clearExpiredInboundAwaitingPeerRelease() external returns (uint256 clearedCount, uint256 clearedAmount);
}
