// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { SuperEarnV2Protocol } from "../../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../../messaging/runespear/RunespearProtocol.sol";
import { BridgeQueue } from "./BridgeQueue.sol";
import { IBridgeAccountant } from "../../interfaces/IBridgeAccountant.sol";
import { SuperEarnAccessControl } from "../../base/SuperEarnAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title BridgeAccountant
 * @notice Manages all bridge-related accounting, tracking, and overlap calculations
 * @dev Separates accounting logic from CrosschainAdapter infrastructure
 *
 * ## ARCHITECTURAL ROLE
 *
 * This accountant is the **accounting layer** for crosschain bridge operations:
 * - CrosschainAdapter = Infrastructure (bridge callbacks, message routing, asset handling)
 * - BridgeAccountant = Accounting (tracking, calculations, reconciliation, overlap logic)
 * - Vaults = Business logic (vault operations, user-facing functions)
 *
 * ## DUAL PENDING NONCE SYSTEM
 *
 * This accountant tracks TWO SEPARATE types of "pending nonces":
 *
 * **A. OUTBOUND Awaiting Peer Receipt (_outboundTracker.outboundAwaitingPeerReceipt):**
 * - Nonces of bridge operations WE initiated
 * - Added when adapter calls allocateOutboundNonce() (or recordOutbound() for legacy flows)
 * - Removed when peer reports receipt (via reconciliation)
 * - Represents: Assets we sent that await peer receipt confirmation
 *
 * **B. INBOUND Awaiting Asset Delivery (_awaitingAssetQueue):**
 * - Nonces from SYNC_BRIDGED notifications PEER sent us
 * - Added when notification arrives but assets haven't arrived yet
 * - Removed when assets arrive and we process the notification
 * - Represents: Notifications waiting for asset arrival
 *
 * ## OVERLAP PREVENTION
 *
 * The accountant prevents double-counting through two mechanisms:
 *
 * 1. **Outbound Overlap:** Assets we sent that peer already confirmed
 *    - Used in: calculateTrueOutboundInTransit()
 *    - Formula: myOutbound - (intersection with their received nonces)
 *
 * 2. **Inbound Overlap:** Assets we received that peer still counts
 *    - Used in: calculateInboundOverlap()
 *    - Formula: sum of (our received operations that match their outbound nonces)
 *
 * ## NONCE DISCIPLINE
 *
 * Both chains must advance outbound nonces monotonically. Any reset must explicitly jump forward
 * (e.g., governance seeding the nonce to block.timestamp) to avoid collisions with the peer's history.
 */
contract BridgeAccountant is Initializable, IBridgeAccountant, SuperEarnAccessControl {
    using BridgeQueue for BridgeQueue.State;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // Errors
    // ============================================

    error InvalidAddress();
    error NonceCannotDecrease(uint256 newNonce, uint256 latestOutboundNonce);

    // ============================================
    // State Variables
    // ============================================

    /// @notice CrosschainAdapter that can modify state
    /// @dev Storage: 1 slot (address = 20 bytes)
    address public override adapter;

    /// @notice Tracker for outbound bridge operations (sent to peer)
    /// @dev Contains outboundAwaitingPeerReceipt[] = nonces of bridges WE sent awaiting peer receipt
    ///      Storage: 9 slots
    ///        - operations (mapping pointer): 1 slot
    ///        - latestOutboundNonce: 1 slot (uint256)
    ///        - totalInTransit: 1 slot (uint256)
    ///        - outboundAwaitingPeerReceipt.length: 1 slot (uint256[])
    ///        - outboundAwaitingPeerReceiptIndex (mapping pointer): 1 slot
    ///        - timeout: 1 slot (uint256)
    ///        - receivedOperations (mapping pointer): 1 slot
    ///        - inboundAwaitingPeerRelease.length: 1 slot (uint256[])
    ///        - inboundAwaitingPeerReleaseIndex (mapping pointer): 1 slot
    BridgeQueue.State internal _outboundTracker;

    /// @notice Tracker for inbound bridge operations (received from peer)
    /// @dev Contains inboundAwaitingPeerRelease[] = nonces the peer sent that we processed and are waiting for peer
    /// release
    ///      Storage: 9 slots (same structure as _outboundTracker)
    ///        - operations (mapping pointer): 1 slot
    ///        - latestOutboundNonce: 1 slot (uint256)
    ///        - totalInTransit: 1 slot (uint256)
    ///        - outboundAwaitingPeerReceipt.length: 1 slot (uint256[])
    ///        - outboundAwaitingPeerReceiptIndex (mapping pointer): 1 slot
    ///        - timeout: 1 slot (uint256)
    ///        - receivedOperations (mapping pointer): 1 slot
    ///        - inboundAwaitingPeerRelease.length: 1 slot (uint256[])
    ///        - inboundAwaitingPeerReleaseIndex (mapping pointer): 1 slot
    BridgeQueue.State internal _inboundTracker;

    /// @notice Bridge notifications awaiting asset delivery queue
    /// @dev Stores SYNC_BRIDGED notifications from peer when assets haven't arrived yet
    ///      Managed by BridgeQueue library
    ///      Storage: 3 slots
    ///        - notifications (mapping pointer): 1 slot
    ///        - awaitingAssetNonces.length: 1 slot (uint256[])
    ///        - awaitingAssetNonceIndex (mapping pointer): 1 slot
    BridgeQueue.PendingBridgedQueue private _awaitingAssetQueue;

    /// @notice Last known complete state snapshot from peer
    /// @dev Updated on EVERY message received via universal state piggybacking
    ///      Contains both vault state and bridge state synchronized at same timestamp
    ///      Single source of truth for:
    ///      - Overlap calculations (calculateInboundOverlap)
    ///      - Vault totalAssets queries (getPeerReportedAssets)
    ///      - Bridge reconciliation (reconcileBridgeState)
    ///      Storage: 10 slots
    ///        - vaultState: 5 slots
    ///          - totalAssets: 1 slot (uint256)
    ///          - idleAssets: 1 slot (uint256)
    ///          - timestamp: 1 slot (uint256)
    ///          - unfulfilledWithdrawalAmount: 1 slot (uint256)
    ///          - assetType: 1 slot (enum, padded to uint256)
    ///        - bridgeState: 5 slots
    ///          - totalOutboundAwaitingPeerReceipt: 1 slot (uint256)
    ///          - totalInboundAwaitingPeerRelease: 1 slot (uint256)
    ///          - outboundAwaitingPeerReceipt.length: 1 slot (uint256[])
    ///          - inboundAwaitingPeerRelease.length: 1 slot (uint256[])
    ///          - timestamp: 1 slot (uint256)
    SuperEarnV2Protocol.StateSnapshot public peerSnapshot;

    // ============================================
    // Initializer
    // ============================================

    /**
     * @notice Initialize the BridgeAccountant
     * @param _adapter Address of the CrosschainAdapter (can be address(0) and set later)
     * @param _owner Owner address that will receive GOVERNANCE_ROLE
     */
    function initialize(address _adapter, address _owner) public initializer {
        __SuperEarnAccessControl_init();

        if (_owner == address(0)) revert InvalidAddress();

        adapter = _adapter;
        _outboundTracker.initialize();
        uint256 initialNonce = block.timestamp;
        if (_outboundTracker.latestOutboundNonce == 0 && initialNonce > 0) {
            _outboundTracker.latestOutboundNonce = initialNonce;
            emit OutboundNonceUpdated(0, initialNonce);
        }
        _inboundTracker.initialize();
        if (_adapter != address(0)) {
            emit AdapterSet(_adapter);
        }

        // Grant GOVERNANCE_ROLE to owner
        _grantRole(GOVERNANCE_ROLE, _owner);
    }

    // ============================================
    // Modifiers
    // ============================================

    /**
     * @notice Ensure only adapter can call state-modifying functions
     */
    modifier onlyAdapter() {
        if (msg.sender != adapter) revert OnlyAdapter();
        _;
    }

    // ============================================
    // Configuration
    // ============================================

    /**
     * @notice Set the adapter address
     * @param _adapter New adapter address
     */
    function setAdapter(address _adapter) external override onlyRole(GOVERNANCE_ROLE) {
        if (_adapter == address(0)) revert InvalidAdapter();
        adapter = _adapter;
        emit AdapterSet(_adapter);
    }

    // ============================================
    // State Recording (Adapter → Accountant)
    // ============================================

    /**
     * @notice Allocate and record an outbound bridge operation
     * @dev Generates the next outbound nonce and records the amount atomically
     * @param amount Amount of assets being sent
     * @return nonce Newly allocated nonce for the operation
     */
    function allocateOutboundNonce(uint256 amount) external override onlyAdapter returns (uint256 nonce) {
        nonce = _outboundTracker.initiateBridge(amount);
        emit OutboundRecorded(nonce, amount, block.timestamp);
    }

    /**
     * @notice Record an outbound bridge operation
     * @dev Called by adapter when sending assets to peer using an externally provided nonce
     * @param nonce Unique nonce for this operation
     * @param amount Amount of assets being sent
     */
    function recordOutbound(uint256 nonce, uint256 amount) external override onlyAdapter {
        _outboundTracker.recordSentOperation(nonce, amount);
        emit OutboundRecorded(nonce, amount, block.timestamp);
    }

    /**
     * @notice Record an inbound bridge operation
     * @dev Called by adapter when receiving assets from peer
     * @param nonce Unique nonce from sender (peer)
     * @param amount Amount of assets received
     * @param sentAt When the bridge was initiated on source chain (from Bridged.timestamp)
     */
    function recordInbound(uint256 nonce, uint256 amount, uint256 sentAt) external override onlyAdapter {
        _inboundTracker.recordReceivedOperation(nonce, amount, sentAt);
        emit InboundRecorded(nonce, amount, block.timestamp);
    }

    /**
     * @notice Add a pending bridge notification
     * @dev Called when SYNC_BRIDGED message arrives but assets haven't arrived yet
     * @param notification Bridge notification from peer
     */
    function addAwaitingAssetNotification(RunespearProtocol.Bridged memory notification)
        external
        override
        onlyAdapter
    {
        BridgeQueue.addAwaitingAssetNotification(_awaitingAssetQueue, notification);
    }

    /**
     * @notice Remove a pending notification
     * @dev Called after successfully processing a notification
     * @param nonce The nonce to remove
     */
    function removeAwaitingAssetNotification(uint256 nonce) external override onlyAdapter {
        BridgeQueue.removeAwaitingAssetNotification(_awaitingAssetQueue, nonce);
    }

    /**
     * @notice Update peer state snapshot
     * @dev Called on every message received from peer
     * @param snapshot Complete state snapshot from peer (vault state + bridge state)
     */
    function updatePeerSnapshot(SuperEarnV2Protocol.StateSnapshot memory snapshot) external override onlyAdapter {
        peerSnapshot = snapshot;
        emit PeerSnapshotUpdated(snapshot.vaultState.timestamp, snapshot.vaultState.totalAssets);
    }

    /**
     * @notice Reconcile bridge operations using peer's reported state.
     * @dev Automatically records peer receipt for outbound operations and peer release for inbound operations
     *      Called whenever we receive a message with piggybacked bridge state
     *
     * @param sourceChainId Chain ID of the peer
     * @param peerBridgeState The peer's piggybacked bridge state
     * @return result Arrays of outbound nonces the peer marked received and inbound nonces the peer released
     */
    function reconcileBridgeState(
        uint256 sourceChainId,
        RunespearProtocol.BridgeState memory peerBridgeState
    )
        external
        override
        onlyAdapter
        returns (BridgeQueue.ReconciliationResult memory result)
    {
        result = BridgeQueue.reconcile(
            _outboundTracker,
            _inboundTracker,
            peerBridgeState.inboundAwaitingPeerRelease,
            peerBridgeState.outboundAwaitingPeerReceipt
        );

        emit BridgeStateReconciled(
            sourceChainId, result.outboundReceivedByPeer.length, result.inboundReleasedByPeer.length
        );

        return result;
    }

    // ============================================
    // View Functions - Calculations
    // ============================================

    /**
     * @notice Get the highest outbound nonce allocated so far
     * @return Highest nonce value recorded in outbound tracker
     */
    function getCurrentOutboundNonce() external view override returns (uint256) {
        return _outboundTracker.latestOutboundNonce;
    }

    /**
     * @notice Check if an inbound operation has been recorded
     * @param nonce Nonce to inspect
     * @return True if recorded in inbound tracker
     */
    function isInboundRecorded(uint256 nonce) external view override returns (bool) {
        return BridgeQueue.hasReceivedOperation(_inboundTracker, nonce);
    }

    /**
     * @notice Check if an inbound operation is awaiting peer release
     * @param nonce Nonce to inspect
     * @return True if recorded but not yet released by the peer
     */
    function isInboundAwaitingPeerRelease(uint256 nonce) external view override returns (bool) {
        return BridgeQueue.isInboundAwaitingPeerRelease(_inboundTracker, nonce);
    }

    /**
     * @notice Calculate true outbound in-transit (with overlap removed)
     * @dev Used by vault for totalAssets calculation
     *
     * Formula: myOutbound - overlap
     * Where overlap = intersection of (my outbound nonces) and (their received nonces from snapshot)
     *
     * @return Amount of assets truly in-transit to peer (not yet confirmed)
     */
    function calculateTrueOutboundInTransit() external view override returns (uint256) {
        uint256 myOutbound = _outboundTracker.getTotalInTransit();
        RunespearProtocol.BridgeState memory peer = peerSnapshot.bridgeState;
        uint256 overlapAmount = BridgeQueue.calculateOverlapAmount(_outboundTracker, peer.inboundAwaitingPeerRelease);
        return myOutbound > overlapAmount ? myOutbound - overlapAmount : 0;
    }

    /**
     * @notice Calculate inbound overlap for double-counting prevention
     * @dev Calculates assets received that were in peer's outbound at snapshot time
     *
     * This prevents double-counting when:
     * - Peer's totalAssets includes assets in-transit (outbound to us)
     * - We've received those assets and count them locally
     * - Without adjustment, system would count the same assets twice
     *
     * CRITICAL: Uses bridge state synchronized with vault state timestamp
     * - peerSnapshot.bridgeState.outboundAwaitingPeerReceipt from snapshot time (NOT current state)
     * - Ensures we only subtract assets that were in-transit AT SNAPSHOT TIME
     * - ONLY counts receives that were SENT BEFORE the snapshot timestamp
     *
     * CRITICAL: Uses sentAt (source chain timestamp) instead of receivedAt
     * - sentAt: When bridge was initiated on peer's chain (same chain as snapshot)
     * - receivedAt: When assets arrived on our chain (different chain, wrong for comparison)
     * - Comparing sentAt with snapshotTime ensures correct causality
     *
     * @return Overlap amount to subtract from their reported assets
     */
    function calculateInboundOverlap() public view override returns (uint256) {
        uint256 snapshotTime = peerSnapshot.vaultState.timestamp;
        uint256[] memory theirOutbound = peerSnapshot.bridgeState.outboundAwaitingPeerReceipt;
        return BridgeQueue.calculateInboundOverlap(_inboundTracker, snapshotTime, theirOutbound);
    }

    /**
     * @notice Calculate true peer assets (reported minus overlap, adjusted for timing)
     * @dev Used by vault for remoteAssets() calculation
     *
     * Formula: peerReportedAssets - receivesNewerThanSnapshot - inboundOverlap
     *
     * Example 1 (Normal case):
     * - Peer reports totalAssets = 1000 USDC
     * - Peer's snapshot shows outboundAwaitingPeerReceipt = [10] (sent 100 USDC to us)
     * - We already received nonce 10 (100 USDC in our vault)
     * - Overlap = 100 USDC
     * - True peer assets = 1000 - 100 = 900 USDC ✓
     *
     * Example 2 (Stale snapshot - THE BUG THIS FIXES):
     * - Peer snapshot at T=1000: totalAssets = 1000 USDC, outboundAwaitingPeerReceipt = []
     * - Peer sends 500 USDC at T=2000 (nonce=10) - AFTER snapshot
     * - We receive 500 USDC at T=3000 (timestamp=3000)
     * - receivesNewerThanSnapshot = 500 (received after T=1000)
     * - overlap = 0 (no matching nonces in snapshot's outboundAwaitingPeerReceipt)
     * - True peer assets = 1000 - 500 - 0 = 500 USDC ✓
     * - (Without fix: would be 1000 - 0 = 1000, causing double-counting!)
     *
     * @return assets True peer assets (overlap-adjusted and timing-adjusted)
     * @return assetType Asset denomination reported in peer snapshot
     */
    function calculateTruePeerAssets()
        external
        view
        override
        returns (uint256 assets, SuperEarnV2Protocol.AssetType assetType)
    {
        uint256 reportedAssets = peerSnapshot.vaultState.totalAssets;
        assetType = peerSnapshot.vaultState.assetType;

        // First: subtract receives that came AFTER the peer's snapshot
        // These assets were sent by peer AFTER their snapshot was taken,
        // so they're NOT reflected in peer's reported totalAssets yet,
        // but they ARE in our local balance already.
        uint256 receivesNewerThanSnapshot = _calculateReceivesNewerThanSnapshot();
        uint256 adjustedReported =
            reportedAssets > receivesNewerThanSnapshot ? reportedAssets - receivesNewerThanSnapshot : 0;

        // Then: subtract normal overlap (for receives BEFORE snapshot)
        uint256 overlap = this.calculateInboundOverlap();

        assets = adjustedReported > overlap ? adjustedReported - overlap : 0;
        return (assets, assetType);
    }

    /**
     * @notice Calculate receives that happened AFTER peer's snapshot timestamp
     * @dev These assets were sent by peer AFTER their snapshot,
     *      so they're NOT reflected in peer's reported totalAssets,
     *      but they ARE in our local balance.
     *
     *      CRITICAL FIX for C-01: Without this, stale snapshots cause double-counting:
     *      - Peer's old snapshot says totalAssets=1000
     *      - Peer sent 500 AFTER snapshot (not in outboundAwaitingPeerReceipt)
     *      - We received the 500 (in our balance)
     *      - Without this function: we'd count peer as having 1000
     *      - With this function: we subtract 500, correctly counting peer as having 500
     *
     *      CRITICAL FIX: Uses sentAt (source chain timestamp) instead of receivedAt
     *      - sentAt: When bridge was initiated on peer's chain (same chain as snapshot)
     *      - receivedAt: When assets arrived on our chain (different chain, wrong for comparison)
     *      - Comparing sentAt with snapshotTime ensures correct causality
     *
     * @return Total amount of receives newer than peer's snapshot
     */
    function _calculateReceivesNewerThanSnapshot() internal view returns (uint256) {
        uint256 snapshotTime = peerSnapshot.vaultState.timestamp;
        return BridgeQueue.sumReceivesAfter(_inboundTracker, snapshotTime);
    }

    /**
     * @notice Get peer's reported total assets (from snapshot)
     * @return Peer's last reported totalAssets
     */
    function getPeerReportedAssets() external view override returns (uint256) {
        return peerSnapshot.vaultState.totalAssets;
    }

    /**
     * @notice Get peer snapshot timestamp
     * @return Timestamp of last peer snapshot update
     */
    function getPeerTimestamp() external view override returns (uint256) {
        return peerSnapshot.vaultState.timestamp;
    }

    /**
     * @notice Get current bridge state
     * @return BridgeState struct with current outbound/inbound tracking
     */
    function getCurrentBridgeState() public view override returns (RunespearProtocol.BridgeState memory) {
        return RunespearProtocol.BridgeState({
            totalOutboundAwaitingPeerReceipt: _outboundTracker.getTotalInTransit(),
            totalInboundAwaitingPeerRelease: _inboundTracker.getTotalInTransit(),
            outboundAwaitingPeerReceipt: _outboundTracker.getOutboundAwaitingPeerReceiptNonces(),
            inboundAwaitingPeerRelease: _inboundTracker.getInboundAwaitingPeerReleaseNonces(),
            timestamp: block.timestamp
        });
    }

    // ============================================
    // View Functions - State Queries
    // ============================================

    /**
     * @notice Get total assets in outbound transit (before overlap adjustment)
     * @return Raw total of outbound operations
     */
    function assetsInTransitOutbound() external view override returns (uint256) {
        return _outboundTracker.getTotalInTransit();
    }

    /**
     * @notice Get total assets in inbound transit (before peer release)
     * @return Raw total of inbound operations
     */
    function assetsInTransitInbound() external view override returns (uint256) {
        return _inboundTracker.getTotalInTransit();
    }

    /**
     * @notice Get outbound nonces awaiting peer receipt
     * @return Array of outbound nonces awaiting peer receipt
     */
    function getOutboundAwaitingPeerReceiptNonces() external view override returns (uint256[] memory) {
        return _outboundTracker.getOutboundAwaitingPeerReceiptNonces();
    }

    /**
     * @notice Get inbound nonces awaiting peer release
     * @return Array of inbound nonces awaiting peer release
     */
    function getInboundAwaitingPeerReleaseNonces() external view override returns (uint256[] memory) {
        return _inboundTracker.getInboundAwaitingPeerReleaseNonces();
    }

    /**
     * @notice Get bridge notification nonces awaiting asset delivery
     * @return Array of nonces with SYNC_BRIDGED notifications awaiting assets
     */
    function getAwaitingAssetNonces() external view override returns (uint256[] memory) {
        return BridgeQueue.getAwaitingAssetNonces(_awaitingAssetQueue);
    }

    /**
     * @notice Get a pending notification
     * @param nonce The nonce to look up
     * @return exists Whether notification exists
     * @return notification The notification (empty if doesn't exist)
     */
    function getAwaitingAssetNotification(uint256 nonce)
        external
        view
        override
        returns (bool exists, RunespearProtocol.Bridged memory notification)
    {
        return BridgeQueue.getAwaitingAssetNotification(_awaitingAssetQueue, nonce);
    }

    /**
     * @notice Get count of bridge notifications awaiting assets
     * @return Number of notifications still waiting on assets
     */
    function getAwaitingAssetCount() external view override returns (uint256) {
        return BridgeQueue.getAwaitingAssetCount(_awaitingAssetQueue);
    }

    // ============================================
    // View Functions - Debug/Monitoring
    // ============================================

    /**
     * @notice Get peer's outbound nonces from snapshot
     * @return Array of peer's outbound nonces at snapshot time
     */
    function getPeerSnapshotOutboundNonces() external view override returns (uint256[] memory) {
        return peerSnapshot.bridgeState.outboundAwaitingPeerReceipt;
    }

    /**
     * @notice Get inbound received nonces
     * @return Array of nonces we've received
     */
    function getInboundReceivedPendingNonces() external view override returns (uint256[] memory) {
        return _inboundTracker.getInboundAwaitingPeerReleaseNonces();
    }

    // ============================================
    // Admin Functions
    // ============================================

    /**
     * @notice Set the outbound nonce pointer for migrations or recovery
     * @param newNonce New nonce value (must not decrease current)
     */
    function forceSetOutboundNonce(uint256 newNonce) external onlyAdapter {
        uint256 current = _outboundTracker.latestOutboundNonce;
        if (newNonce < current) revert NonceCannotDecrease(newNonce, current);
        _outboundTracker.latestOutboundNonce = newNonce;
        emit OutboundNonceUpdated(current, newNonce);
    }

    /**
     * @notice Set timeout for bridge operations
     * @param newTimeout New timeout duration in seconds
     */
    function setBridgeTimeout(uint256 newTimeout) external override onlyManagers {
        _outboundTracker.setTimeout(newTimeout);
        _inboundTracker.setTimeout(newTimeout);
    }

    /**
     * @notice Manually clear an outbound operation by nonce
     * @param nonce The nonce to clear
     */
    function forceManualClearOutboundByNonce(uint256 nonce) external onlyGovernance {
        _outboundTracker.manualClearOutboundByNonce(nonce);
    }

    /**
     * @notice Manually clear outbound operations by amount
     * @param amount Amount to clear
     */
    function forceManualClearOutboundByAmount(uint256 amount) external onlyGovernance {
        _outboundTracker.manualClearOutboundByAmount(amount);
    }

    /**
     * @notice Clear expired outbound operations
     * @return clearedCount Number of operations cleared
     * @return clearedAmount Total amount cleared
     */
    function clearExpiredOutboundAwaitingPeerReceipt()
        external
        override
        onlyGovernance
        returns (uint256 clearedCount, uint256 clearedAmount)
    {
        return _outboundTracker.clearExpiredOutboundAwaitingPeerReceipt();
    }

    /**
     * @notice Manually clear an inbound operation by nonce
     * @param nonce The nonce to clear
     */
    function forceManualReleaseInboundByNonce(uint256 nonce) external onlyGovernance {
        BridgeQueue.manualReleaseInboundByNonce(_inboundTracker, nonce);
    }

    /**
     * @notice Manually clear inbound operations by amount
     * @param amount Amount to clear
     */
    function forceManualReleaseInboundByAmount(uint256 amount) external onlyGovernance {
        BridgeQueue.manualReleaseInboundByAmount(_inboundTracker, amount);
    }

    /**
     * @notice Clear expired inbound operations
     * @return clearedCount Number of operations cleared
     * @return clearedAmount Total amount cleared
     */
    function clearExpiredInboundAwaitingPeerRelease()
        external
        override
        onlyGovernance
        returns (uint256 clearedCount, uint256 clearedAmount)
    {
        return BridgeQueue.clearExpiredInboundAwaitingPeerRelease(_inboundTracker);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 32 slots
     *   - adapter: 1 slot (address)
     *   - _outboundTracker: 9 slots
     *     - operations (mapping pointer): 1 slot
     *     - latestOutboundNonce: 1 slot (uint256)
     *     - totalInTransit: 1 slot (uint256)
     *     - outboundAwaitingPeerReceipt.length: 1 slot (uint256[])
     *     - outboundAwaitingPeerReceiptIndex (mapping pointer): 1 slot
     *     - timeout: 1 slot (uint256)
     *     - receivedOperations (mapping pointer): 1 slot
     *     - inboundAwaitingPeerRelease.length: 1 slot (uint256[])
     *     - inboundAwaitingPeerReleaseIndex (mapping pointer): 1 slot
     *   - _inboundTracker: 9 slots (same structure as _outboundTracker)
     *     - operations (mapping pointer): 1 slot
     *     - latestOutboundNonce: 1 slot (uint256)
     *     - totalInTransit: 1 slot (uint256)
     *     - outboundAwaitingPeerReceipt.length: 1 slot (uint256[])
     *     - outboundAwaitingPeerReceiptIndex (mapping pointer): 1 slot
     *     - timeout: 1 slot (uint256)
     *     - receivedOperations (mapping pointer): 1 slot
     *     - inboundAwaitingPeerRelease.length: 1 slot (uint256[])
     *     - inboundAwaitingPeerReleaseIndex (mapping pointer): 1 slot
     *   - _awaitingAssetQueue: 3 slots
     *     - notifications (mapping pointer): 1 slot
     *     - awaitingAssetNonces.length: 1 slot (uint256[])
     *     - awaitingAssetNonceIndex (mapping pointer): 1 slot
     *   - peerSnapshot: 10 slots
     *     - vaultState: 5 slots
     *       - totalAssets: 1 slot (uint256)
     *       - idleAssets: 1 slot (uint256)
     *       - timestamp: 1 slot (uint256)
     *       - unfulfilledWithdrawalAmount: 1 slot (uint256)
     *       - assetType: 1 slot (enum, padded to uint256)
     *     - bridgeState: 5 slots
     *       - totalOutboundAwaitingPeerReceipt: 1 slot (uint256)
     *       - totalInboundAwaitingPeerRelease: 1 slot (uint256)
     *       - outboundAwaitingPeerReceipt.length: 1 slot (uint256[])
     *       - inboundAwaitingPeerRelease.length: 1 slot (uint256[])
     *       - timestamp: 1 slot (uint256)
     *
     * Note: Mappings (operations, outboundAwaitingPeerReceiptIndex, receivedOperations,
     *       inboundAwaitingPeerReleaseIndex, notifications, awaitingAssetNonceIndex) don't use
     *       direct storage slots - they use keccak256-based storage locations.
     *
     * Gap = 50 - 32 = 18
     */
    uint256[18] private __gap;
}
