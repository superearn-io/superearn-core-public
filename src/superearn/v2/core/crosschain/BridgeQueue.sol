// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { RunespearProtocol } from "../../messaging/runespear/RunespearProtocol.sol";

/**
 * @title BridgeQueue
 * @notice Library for tracking asynchronous bridge operations with timeout-based recovery
 * @dev Solves the problem of stuck assets when bridge callbacks or CCIP messages fail
 *
 * Problem Context:
 * - Bridge callbacks may fail (gas, authorization, revert)
 * - CCIP messages may fail (network issues, revert, out of gas)
 * - Result: assetsInTransit stuck forever, causing accounting errors
 *
 * Solution:
 * - Unique nonce per bridge operation
 * - Timestamp tracking for timeout detection
 * - Idempotent confirmation processing
 * - Manual recovery for owner
 * - Timeout-based auto-recovery
 *
 * Nonce Discipline:
 * - Both this chain and the peer must advance outbound nonces monotonically
 * - Reusing or decreasing a nonce can cause reconciliation collisions and asset mis-accounting
 */
library BridgeQueue {
    // === Errors ===
    error BridgeOperationNotFound(uint256 nonce);
    error BridgeOperationAlreadyConfirmed(uint256 nonce);
    error BridgeOperationNotExpired(uint256 nonce, uint256 timeRemaining);
    error InvalidAmount();
    error InvalidTimeout();
    error IncompleteClear(uint256 requestedAmount, uint256 actualCleared, uint256 remaining);

    // === Events ===
    event BridgeInitiated(uint256 indexed nonce, uint256 amount, uint256 timestamp);
    event BridgeConfirmed(uint256 indexed nonce, uint256 amount, uint256 timestamp);
    event BridgeExpired(uint256 indexed nonce, uint256 amount, uint256 timestamp);
    event BridgeManuallyClearedByNonce(uint256 indexed nonce, uint256 amount);
    event BridgeManuallyClearedByAmount(uint256 amount);
    event TimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    // === Constants ===
    uint256 public constant DEFAULT_TIMEOUT = 24 hours;
    uint256 public constant MAX_TIMEOUT = 7 days;

    // === Structs ===

    /**
     * @notice Represents a single bridge operation (outbound - initiated by us)
     * @param nonce Unique identifier for this bridge operation
     * @param amount Amount of assets being bridged (in target token terms)
     * @param timestamp When the bridge was initiated
     * @param peerReceiptRecorded Whether we have proof the peer received the assets
     */
    struct Sent {
        uint256 nonce;
        uint256 amount;
        uint256 timestamp;
        bool peerReceiptRecorded;
    }

    /**
     * @notice Represents a received bridge operation (inbound - initiated by peer)
     * @param nonce Nonce assigned by the sender (peer)
     * @param amount Amount of assets received
     * @param sentAt When the bridge was initiated on SOURCE chain (from Bridged.timestamp)
     * @param receivedAt When we received and processed the assets on THIS chain (block.timestamp)
     * @param peerReleased Whether the peer has released this nonce from their outbound tracker
     * @dev Used to track operations where we are the receiver, not the sender
     * @dev sentAt is used for causality/overlap calculations (compare with peer snapshots)
     * @dev receivedAt is used for timeout/staleness detection
     */
    struct Received {
        uint256 nonce;
        uint256 amount;
        uint256 sentAt;
        uint256 receivedAt;
        bool peerReleased;
    }

    /**
     * @notice Result of bridge state reconciliation between this chain and peer
     * @dev Two-way handshake: record when the peer receives my sends, record when the peer releases their sends
     *
     * @param outboundReceivedByPeer My outbound nonces that the peer reported as received
     *        - These are operations I sent to the peer
     *        - The peer reported them in their inboundAwaitingPeerRelease list
     *        - I can now remove them from my outbound-awaiting-receipt tracker
     *
     * @param inboundReleasedByPeer My inbound nonces that the peer released from their outbound tracker
     *        - These are operations the peer sent to me (I hold the funds)
     *        - The peer removed them from their outboundAwaitingPeerReceipt list
     *        - I can now mark the inbound release complete on my side
     */
    struct ReconciliationResult {
        uint256[] outboundReceivedByPeer;
        uint256[] inboundReleasedByPeer;
    }

    /**
     * @notice Queue for pending bridge notifications awaiting asset arrival
     * @param notifications Mapping of nonce to bridge notification
     * @param awaitingAssetNonces Array of nonces with notifications waiting on asset delivery
     * @param awaitingAssetNonceIndex Mapping of nonce to index in awaitingAssetNonces array
     * @dev Tracks SYNC_BRIDGED notifications received before assets arrive
     *      Used for out-of-order bridge completion (message arrives before assets)
     */
    struct PendingBridgedQueue {
        mapping(uint256 => RunespearProtocol.Bridged) notifications;
        uint256[] awaitingAssetNonces;
        mapping(uint256 => uint256) awaitingAssetNonceIndex;
    }

    /**
     * @notice State container for bridge tracking
     * @param operations Mapping of nonce to bridge operation (outbound operations we initiated)
     * @param latestOutboundNonce Next nonce to use for operations we initiate (must only increase)
     * @param totalInTransit Total amount currently in transit (awaiting either receipt or release)
     * @param outboundAwaitingPeerReceipt Array of outbound nonces awaiting peer receipt confirmation
     * @param outboundAwaitingPeerReceiptIndex Mapping of outbound nonce to its index within outboundAwaitingPeerReceipt
     * @param timeout Timeout duration before operations can be cleared
     * @param receivedOperations Mapping of nonce to received operation (inbound from peer)
     * @param inboundAwaitingPeerRelease Array of inbound nonces awaiting the peer to release them from outbound
     * tracking
     * @param inboundAwaitingPeerReleaseIndex Mapping of inbound nonce to its index within inboundAwaitingPeerRelease
     * @dev Tracks both outbound (we send) and inbound (we receive) bridge operations
     */
    struct State {
        // Outbound tracking (operations we initiate)
        mapping(uint256 => Sent) operations;
        uint256 latestOutboundNonce;
        uint256 totalInTransit;
        uint256[] outboundAwaitingPeerReceipt;
        mapping(uint256 => uint256) outboundAwaitingPeerReceiptIndex;
        uint256 timeout;
        // Inbound tracking (operations initiated by peer)
        mapping(uint256 => Received) receivedOperations;
        uint256[] inboundAwaitingPeerRelease;
        mapping(uint256 => uint256) inboundAwaitingPeerReleaseIndex;
    }

    // === Initialization ===

    /**
     * @notice Initialize the bridge tracker with default timeout
     * @param state The bridge tracker state
     */
    function initialize(State storage state) public {
        if (state.timeout == 0) {
            state.timeout = DEFAULT_TIMEOUT;
        }
    }

    /**
     * @notice Set custom timeout for bridge operations
     * @param state The bridge tracker state
     * @param newTimeout The new timeout duration
     */
    function setTimeout(State storage state, uint256 newTimeout) public {
        if (newTimeout == 0 || newTimeout > MAX_TIMEOUT) revert InvalidTimeout();
        uint256 oldTimeout = state.timeout;
        state.timeout = newTimeout;
        emit TimeoutUpdated(oldTimeout, newTimeout);
    }

    // === Core Functions ===

    /**
     * @notice Initiate a new bridge operation
     * @param state The bridge tracker state
     * @param amount Amount of assets being bridged
     * @return nonce The unique nonce for this operation
     */
    function initiateBridge(State storage state, uint256 amount) internal returns (uint256 nonce) {
        if (amount == 0) revert InvalidAmount();

        // Ensure timeout is initialized
        if (state.timeout == 0) {
            state.timeout = DEFAULT_TIMEOUT;
        }

        // Generate new nonce
        nonce = ++state.latestOutboundNonce;

        // Create operation record
        Sent storage op = state.operations[nonce];
        op.nonce = nonce;
        op.amount = amount;
        op.timestamp = block.timestamp;
        op.peerReceiptRecorded = false;

        // Add to outbound-awaiting-receipt array
        state.outboundAwaitingPeerReceiptIndex[nonce] = state.outboundAwaitingPeerReceipt.length;
        state.outboundAwaitingPeerReceipt.push(nonce);

        // Update total in transit
        state.totalInTransit += amount;

        emit BridgeInitiated(nonce, amount, block.timestamp);

        return nonce;
    }

    /**
     * @notice Record a sent bridge operation with external nonce
     * @dev Used when nonce is provided by external adapter (mirrors recordReceivedOperation naming)
     * @param state The bridge tracker state
     * @param nonce Nonce provided by external system (e.g., CrosschainAdapter)
     * @param amount Amount of assets being bridged
     */
    function recordSentOperation(State storage state, uint256 nonce, uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        if (nonce == 0) revert InvalidAmount();

        // Ensure timeout is initialized
        if (state.timeout == 0) {
            state.timeout = DEFAULT_TIMEOUT;
        }

        // Update latestOutboundNonce if nonce is higher (keep in sync)
        if (nonce > state.latestOutboundNonce) {
            state.latestOutboundNonce = nonce;
        }

        // Create operation record with provided nonce
        Sent storage op = state.operations[nonce];
        op.nonce = nonce;
        op.amount = amount;
        op.timestamp = block.timestamp;
        op.peerReceiptRecorded = false;

        // Add to outbound-awaiting-receipt array
        state.outboundAwaitingPeerReceiptIndex[nonce] = state.outboundAwaitingPeerReceipt.length;
        state.outboundAwaitingPeerReceipt.push(nonce);

        // Update total in transit
        state.totalInTransit += amount;

        emit BridgeInitiated(nonce, amount, block.timestamp);
    }

    /**
     * @notice Confirm a bridge operation (idempotent)
     * @param state The bridge tracker state
     * @param nonce The nonce of the operation to confirm
     */
    function confirmBridge(State storage state, uint256 nonce) public {
        Sent storage op = state.operations[nonce];

        // Check if operation exists
        if (op.timestamp == 0) revert BridgeOperationNotFound(nonce);

        // Idempotent: if already confirmed, skip
        if (op.peerReceiptRecorded) {
            return; // Silently succeed for idempotency
        }

        // Mark as confirmed
        op.peerReceiptRecorded = true;

        // Update total in transit
        state.totalInTransit -= op.amount;

        // Remove from the inbound-awaiting-peer-release array
        _removeOutboundAwaitingPeerReceipt(state, nonce);

        emit BridgeConfirmed(nonce, op.amount, block.timestamp);
    }

    /**
     * @notice Clear outbound bridge operations that exceeded the receipt timeout
     * @param state The bridge tracker state
     * @return clearedCount Number of operations cleared
     * @return clearedAmount Total amount cleared
     */
    function clearExpiredOutboundAwaitingPeerReceipt(State storage state)
        internal
        returns (uint256 clearedCount, uint256 clearedAmount)
    {
        uint256 currentTime = block.timestamp;
        uint256 timeout = state.timeout > 0 ? state.timeout : DEFAULT_TIMEOUT;

        // Iterate through outbound awaiting receipt (in reverse to avoid index issues)
        uint256 i = state.outboundAwaitingPeerReceipt.length;
        while (i > 0) {
            i--;
            uint256 nonce = state.outboundAwaitingPeerReceipt[i];
            Sent storage op = state.operations[nonce];

            // Check if expired
            if (!op.peerReceiptRecorded && currentTime >= op.timestamp + timeout) {
                // Clear this operation
                clearedAmount += op.amount;
                clearedCount++;

                // Update total in transit
                state.totalInTransit -= op.amount;

                // Mark as recorded (to prevent re-processing)
                op.peerReceiptRecorded = true;

                // Remove from the outbound-awaiting-receipt array
                _removeOutboundAwaitingPeerReceipt(state, nonce);

                emit BridgeExpired(nonce, op.amount, block.timestamp);
            }
        }

        return (clearedCount, clearedAmount);
    }

    /**
     * @notice Manually clear a specific outbound bridge operation by nonce
     * @param state The bridge tracker state
     * @param nonce The nonce to clear
     */
    function manualClearOutboundByNonce(State storage state, uint256 nonce) public {
        Sent storage op = state.operations[nonce];

        // Check if operation exists
        if (op.timestamp == 0) revert BridgeOperationNotFound(nonce);

        // Check if peer receipt already recorded
        if (op.peerReceiptRecorded) revert BridgeOperationAlreadyConfirmed(nonce);

        // Clear the operation
        state.totalInTransit -= op.amount;
        op.peerReceiptRecorded = true;

        // Remove from the outbound-awaiting-receipt array
        _removeOutboundAwaitingPeerReceipt(state, nonce);

        emit BridgeManuallyClearedByNonce(nonce, op.amount);
    }

    /**
     * @notice Manually clear a specific amount from outbound transit tracking
     * @param state The bridge tracker state
     * @param amount Amount to clear
     * @dev WARNING: Use with caution - clears oldest outbound operations awaiting receipt until amount is reached
     * @dev Reverts if the exact amount cannot be cleared (e.g., if remaining operations are too large)
     */
    function manualClearOutboundByAmount(State storage state, uint256 amount) public {
        if (amount == 0) revert InvalidAmount();
        if (amount > state.totalInTransit) revert InvalidAmount();

        uint256 remainingToClear = amount;
        uint256 totalCleared = 0;
        uint256 i = 0;

        // Clear oldest operations first until amount is cleared
        while (remainingToClear > 0 && i < state.outboundAwaitingPeerReceipt.length) {
            uint256 nonce = state.outboundAwaitingPeerReceipt[i];
            Sent storage op = state.operations[nonce];

            if (!op.peerReceiptRecorded && op.amount <= remainingToClear) {
                // Fully clear this operation
                state.totalInTransit -= op.amount;
                op.peerReceiptRecorded = true;
                remainingToClear -= op.amount;
                totalCleared += op.amount;

                // Remove from the outbound-awaiting-receipt array
                _removeOutboundAwaitingPeerReceipt(state, nonce);
                // Don't increment i since we removed the current element (swap-and-pop means new element at i)
                continue;
            }

            i++;
        }

        // Ensure full amount was cleared
        if (remainingToClear > 0) {
            revert IncompleteClear(amount, totalCleared, remainingToClear);
        }

        emit BridgeManuallyClearedByAmount(totalCleared);
    }

    // === View Functions ===

    /**
     * @notice Get bridge operation details
     * @param state The bridge tracker state
     * @param nonce The nonce to query
     * @return operation The bridge operation struct
     */
    function getOperation(State storage state, uint256 nonce) internal view returns (Sent memory operation) {
        return state.operations[nonce];
    }

    /**
     * @notice Get total assets in transit
     * @param state The bridge tracker state
     * @return Total unconfirmed amount
     */
    function getTotalInTransit(State storage state) public view returns (uint256) {
        return state.totalInTransit;
    }

    /**
     * @notice Get count of outbound operations awaiting peer receipt
     * @param state The bridge tracker state
     * @return Number of outbound operations still awaiting peer receipt
     */
    function getOutboundAwaitingPeerReceiptCount(State storage state) public view returns (uint256) {
        return state.outboundAwaitingPeerReceipt.length;
    }

    /**
     * @notice Get all outbound nonces awaiting peer receipt
     * @param state The bridge tracker state
     * @return Array of outbound nonces still awaiting peer receipt
     */
    function getOutboundAwaitingPeerReceiptNonces(State storage state) public view returns (uint256[] memory) {
        return state.outboundAwaitingPeerReceipt;
    }

    /**
     * @notice Get the amount for a specific operation nonce
     * @param state The bridge tracker state
     * @param nonce The nonce to look up
     * @return amount The amount for this operation (0 if not found)
     */
    function getOperationAmount(State storage state, uint256 nonce) public view returns (uint256) {
        Sent storage op = state.operations[nonce];
        return op.amount;
    }

    /**
     * @notice Check if a bridge operation is expired
     * @param state The bridge tracker state
     * @param nonce The nonce to check
     * @return expired Whether the operation is expired
     * @return timeRemaining Time remaining until expiration (0 if expired)
     */
    function isExpired(
        State storage state,
        uint256 nonce
    )
        internal
        view
        returns (bool expired, uint256 timeRemaining)
    {
        Sent storage op = state.operations[nonce];
        if (op.timestamp == 0 || op.peerReceiptRecorded) {
            return (false, 0);
        }

        uint256 timeout = state.timeout > 0 ? state.timeout : DEFAULT_TIMEOUT;
        uint256 expirationTime = op.timestamp + timeout;

        if (block.timestamp >= expirationTime) {
            return (true, 0);
        } else {
            return (false, expirationTime - block.timestamp);
        }
    }

    /**
     * @notice Get count of expired operations
     * @param state The bridge tracker state
     * @return count Number of expired but uncleared operations
     */
    function getExpiredCount(State storage state) public view returns (uint256 count) {
        uint256 currentTime = block.timestamp;
        uint256 timeout = state.timeout > 0 ? state.timeout : DEFAULT_TIMEOUT;

        for (uint256 i = 0; i < state.outboundAwaitingPeerReceipt.length; i++) {
            uint256 nonce = state.outboundAwaitingPeerReceipt[i];
            Sent storage op = state.operations[nonce];

            if (!op.peerReceiptRecorded && currentTime >= op.timestamp + timeout) {
                count++;
            }
        }

        return count;
    }

    // === Inbound Bridge Tracking Functions ===

    /**
     * @notice Record a bridge operation received from peer
     * @param state The bridge tracker state
     * @param nonce Nonce assigned by the sender (peer)
     * @param amount Amount of assets received
     * @param sentAt When the bridge was initiated on source chain (from Bridged.timestamp)
     * @dev Call this when assets arrive from peer, before acknowledging their release handshake
     * @dev sentAt comes from the source chain's Bridged message, receivedAt is set to current block.timestamp
     */
    function recordReceivedOperation(State storage state, uint256 nonce, uint256 amount, uint256 sentAt) internal {
        if (amount == 0) revert InvalidAmount();

        // Check if already recorded (idempotent)
        if (state.receivedOperations[nonce].receivedAt != 0) {
            return; // Already recorded, skip
        }

        // Create received operation record
        state.receivedOperations[nonce] =
            Received({ nonce: nonce, amount: amount, sentAt: sentAt, receivedAt: block.timestamp, peerReleased: false });

        // Track until peer releases this nonce from their outbound tracker
        state.inboundAwaitingPeerReleaseIndex[nonce] = state.inboundAwaitingPeerRelease.length;
        state.inboundAwaitingPeerRelease.push(nonce);

        // Update total in transit
        state.totalInTransit += amount;

        emit BridgeInitiated(nonce, amount, block.timestamp); // Reuse event
    }

    /**
     * @notice Record that the peer released an inbound operation
     * @param state The bridge tracker state
     * @param nonce Nonce of the received operation
     * @dev Call this after successfully acknowledging the peer release on-chain
     */
    function recordPeerRelease(State storage state, uint256 nonce) public {
        Received storage op = state.receivedOperations[nonce];

        // Check if operation exists
        if (op.receivedAt == 0) revert BridgeOperationNotFound(nonce);

        // Idempotent: if already recorded, skip
        if (op.peerReleased) {
            return;
        }

        // Mark as released
        op.peerReleased = true;

        // Update total in transit
        state.totalInTransit -= op.amount;

        // Remove from the inbound-awaiting-peer-release array
        _removeInboundAwaitingPeerReleaseNonce(state, nonce);

        emit BridgeConfirmed(nonce, op.amount, block.timestamp); // Reuse event
    }

    /**
     * @notice Manually mark a received operation as released by peer for a given nonce
     * @param state The bridge tracker state
     * @param nonce Nonce of the received operation
     * @dev Mirrors manualClearOutboundByNonce but for inbound flows
     */
    function manualReleaseInboundByNonce(State storage state, uint256 nonce) public {
        Received storage op = state.receivedOperations[nonce];

        if (op.receivedAt == 0) revert BridgeOperationNotFound(nonce);
        if (op.peerReleased) revert BridgeOperationAlreadyConfirmed(nonce);

        state.totalInTransit -= op.amount;
        op.peerReleased = true;

        _removeInboundAwaitingPeerReleaseNonce(state, nonce);

        emit BridgeManuallyClearedByNonce(nonce, op.amount);
    }

    /**
     * @notice Manually mark inbound releases up to an amount
     * @param state The bridge tracker state
     * @param amount Amount to clear from inbound transit
     * @dev Clears oldest release-waiting entries until amount satisfied, reverts if exact amount cannot be met
     */
    function manualReleaseInboundByAmount(State storage state, uint256 amount) public {
        if (amount == 0) revert InvalidAmount();
        if (amount > state.totalInTransit) revert InvalidAmount();

        uint256 remainingToClear = amount;
        uint256 totalCleared = 0;
        uint256 i = 0;

        while (remainingToClear > 0 && i < state.inboundAwaitingPeerRelease.length) {
            uint256 nonce = state.inboundAwaitingPeerRelease[i];
            Received storage op = state.receivedOperations[nonce];

            if (!op.peerReleased && op.amount <= remainingToClear) {
                state.totalInTransit -= op.amount;
                op.peerReleased = true;
                remainingToClear -= op.amount;
                totalCleared += op.amount;

                _removeInboundAwaitingPeerReleaseNonce(state, nonce);
                continue;
            }

            i++;
        }

        if (remainingToClear > 0) {
            revert IncompleteClear(amount, totalCleared, remainingToClear);
        }

        emit BridgeManuallyClearedByAmount(totalCleared);
    }

    /**
     * @notice Clear expired inbound (received) operations awaiting peer release
     * @param state The bridge tracker state
     * @return clearedCount Number of operations cleared
     * @return clearedAmount Total amount cleared
     * @dev Uses receivedAt timestamp to determine expiration
     */
    function clearExpiredInboundAwaitingPeerRelease(State storage state)
        internal
        returns (uint256 clearedCount, uint256 clearedAmount)
    {
        uint256 currentTime = block.timestamp;
        uint256 timeout = state.timeout > 0 ? state.timeout : DEFAULT_TIMEOUT;

        uint256 i = state.inboundAwaitingPeerRelease.length;
        while (i > 0) {
            i--;
            uint256 nonce = state.inboundAwaitingPeerRelease[i];
            Received storage op = state.receivedOperations[nonce];

            if (!op.peerReleased && currentTime >= op.receivedAt + timeout) {
                clearedAmount += op.amount;
                clearedCount++;

                state.totalInTransit -= op.amount;
                op.peerReleased = true;

                _removeInboundAwaitingPeerReleaseNonce(state, nonce);

                emit BridgeExpired(nonce, op.amount, block.timestamp);
            }
        }

        return (clearedCount, clearedAmount);
    }

    /**
     * @notice Get received operation details
     * @param state The bridge tracker state
     * @param nonce The nonce to query
     * @return operation The received operation struct
     */
    function getReceivedOperation(
        State storage state,
        uint256 nonce
    )
        internal
        view
        returns (Received memory operation)
    {
        return state.receivedOperations[nonce];
    }

    /**
     * @notice Get all inbound nonces still waiting for peer release
     * @param state The bridge tracker state
     * @return Array of nonces for received operations the peer has not yet released
     */
    function getInboundAwaitingPeerReleaseNonces(State storage state) internal view returns (uint256[] memory) {
        return state.inboundAwaitingPeerRelease;
    }

    /**
     * @notice Get count of inbound operations awaiting peer release
     * @param state The bridge tracker state
     * @return Number of inbound operations the peer has not yet released
     */
    function getInboundAwaitingPeerReleaseCount(State storage state) public view returns (uint256) {
        return state.inboundAwaitingPeerRelease.length;
    }

    // === Internal Helper Functions ===

    /**
     * @notice Remove a nonce from the outbound-awaiting-receipt array
     * @param state The bridge tracker state
     * @param nonce The nonce to remove
     */
    function _removeOutboundAwaitingPeerReceipt(State storage state, uint256 nonce) private {
        uint256 index = state.outboundAwaitingPeerReceiptIndex[nonce];
        uint256 lastIndex = state.outboundAwaitingPeerReceipt.length - 1;

        // If not the last element, swap with last
        if (index != lastIndex) {
            uint256 lastNonce = state.outboundAwaitingPeerReceipt[lastIndex];
            state.outboundAwaitingPeerReceipt[index] = lastNonce;
            state.outboundAwaitingPeerReceiptIndex[lastNonce] = index;
        }

        // Remove last element
        state.outboundAwaitingPeerReceipt.pop();
        delete state.outboundAwaitingPeerReceiptIndex[nonce];
    }

    /**
     * @notice Check if a nonce currently exists in the outbound-awaiting-receipt queue
     * @param state The bridge tracker state
     * @param nonce The nonce to check
     * @return exists True if the nonce is still awaiting peer receipt
     * @return index Index of the nonce within the queue (undefined when !exists)
     */
    function _getOutboundAwaitingPeerReceiptIndex(
        State storage state,
        uint256 nonce
    )
        private
        view
        returns (bool exists, uint256 index)
    {
        uint256 idx = state.outboundAwaitingPeerReceiptIndex[nonce];
        if (idx >= state.outboundAwaitingPeerReceipt.length) {
            return (false, 0);
        }

        if (state.outboundAwaitingPeerReceipt[idx] != nonce) {
            return (false, 0);
        }

        return (true, idx);
    }

    /**
     * @notice Remove a nonce from the inbound-awaiting-peer-release array
     * @param state The bridge tracker state
     * @param nonce The nonce to remove
     */
    function _removeInboundAwaitingPeerReleaseNonce(State storage state, uint256 nonce) private {
        uint256 index = state.inboundAwaitingPeerReleaseIndex[nonce];
        uint256 lastIndex = state.inboundAwaitingPeerRelease.length - 1;

        // If not the last element, swap with last
        if (index != lastIndex) {
            uint256 lastNonce = state.inboundAwaitingPeerRelease[lastIndex];
            state.inboundAwaitingPeerRelease[index] = lastNonce;
            state.inboundAwaitingPeerReleaseIndex[lastNonce] = index;
        }

        // Remove last element
        state.inboundAwaitingPeerRelease.pop();
        delete state.inboundAwaitingPeerReleaseIndex[nonce];
    }

    /**
     * @notice Check if a nonce currently exists in the inbound-awaiting-peer-release queue
     * @param state The bridge tracker state
     * @param nonce The nonce to check
     * @return exists True if the nonce still awaits peer release
     * @return index Index of the nonce within the queue (undefined when !exists)
     */
    function _getInboundAwaitingPeerReleaseIndex(
        State storage state,
        uint256 nonce
    )
        private
        view
        returns (bool exists, uint256 index)
    {
        uint256 idx = state.inboundAwaitingPeerReleaseIndex[nonce];
        if (idx >= state.inboundAwaitingPeerRelease.length) {
            return (false, 0);
        }

        if (state.inboundAwaitingPeerRelease[idx] != nonce) {
            return (false, 0);
        }

        return (true, idx);
    }

    // ============================================
    // Bridge State Reconciliation
    // ============================================

    /**
     * @notice Deduplicate an array of nonces
     * @param nonces Input array that may contain duplicates
     * @return deduplicated Array with duplicates removed
     */
    function _deduplicateNonces(uint256[] memory nonces) private pure returns (uint256[] memory deduplicated) {
        if (nonces.length == 0) {
            return new uint256[](0);
        }

        // Count unique nonces
        uint256 uniqueCount = 0;
        for (uint256 i = 0; i < nonces.length; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < i; j++) {
                if (nonces[i] == nonces[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                uniqueCount++;
            }
        }

        // Build deduplicated array
        deduplicated = new uint256[](uniqueCount);
        uint256 index = 0;
        for (uint256 i = 0; i < nonces.length; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < i; j++) {
                if (nonces[i] == nonces[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                deduplicated[index++] = nonces[i];
            }
        }

        return deduplicated;
    }

    /**
     * @notice Reconcile bridge operations using peer's reported state
     * @dev Automatically records peer receipt for outbound operations and peer release for inbound operations
     *
     * Two-way reconciliation:
     * 1. Outbound confirmations: If peer reports they received a nonce I sent,
     *    mark it on my outbound tracker and remove from outboundAwaitingPeerReceipt
     * 2. Inbound releases: If a nonce I received is no longer in the peer's outbound tracker,
     *    they've released it, so I can finalize the inbound record locally
     *
     * @param outboundTracker State tracker for operations we sent
     * @param inboundTracker State tracker for operations we received
     * @param peerReceivedNonces Nonces the peer reports they received from us
     * @param peerOutboundNonces Nonces the peer reports are still awaiting receipt on their side
     * @return result Arrays of nonces that were marked as received/released during reconciliation
     */
    function reconcile(
        State storage outboundTracker,
        State storage inboundTracker,
        uint256[] memory peerReceivedNonces,
        uint256[] memory peerOutboundNonces
    )
        public
        returns (ReconciliationResult memory result)
    {
        // Deduplicate input arrays to prevent duplicate processing
        peerReceivedNonces = _deduplicateNonces(peerReceivedNonces);
        peerOutboundNonces = _deduplicateNonces(peerOutboundNonces);
        // ============================================
        // 1. Process confirmations for MY outbound operations
        // ============================================
        // Peer's inboundAwaitingPeerRelease = operations they received from me
        // If they reported it, I can mark my outbound tracker as received

        uint256 outboundReceivedCount = 0;

        // Count how many will be confirmed
        for (uint256 i = 0; i < peerReceivedNonces.length; i++) {
            uint256 nonce = peerReceivedNonces[i];
            (bool exists,) = _getOutboundAwaitingPeerReceiptIndex(outboundTracker, nonce);
            if (exists) outboundReceivedCount++;
        }

        // Allocate result array and confirm operations
        result.outboundReceivedByPeer = new uint256[](outboundReceivedCount);
        uint256 outboundReceivedIndex = 0;

        for (uint256 i = 0; i < peerReceivedNonces.length; i++) {
            uint256 nonce = peerReceivedNonces[i];

            (bool exists,) = _getOutboundAwaitingPeerReceiptIndex(outboundTracker, nonce);

            if (exists) {
                // Peer confirmed receipt - confirm on my side
                confirmBridge(outboundTracker, nonce);
                result.outboundReceivedByPeer[outboundReceivedIndex++] = nonce;
            }
        }

        // ============================================
        // 2. Process releases for my received operations
        // ============================================
        // If I received a nonce that's NOT in the peer's outbound list anymore,
        // they've released it on their side, so I can finalize the inbound record

        uint256[] memory inboundAwaitingPeerReleaseNonces = getInboundAwaitingPeerReleaseNonces(inboundTracker);
        uint256 inboundReleasedCount = 0;
        bool[] memory shouldSkip = new bool[](inboundAwaitingPeerReleaseNonces.length);

        // Mark received nonces that are still in the peer outbound list
        for (uint256 i = 0; i < peerOutboundNonces.length; i++) {
            uint256 peerNonce = peerOutboundNonces[i];
            (bool exists, uint256 index) = _getInboundAwaitingPeerReleaseIndex(inboundTracker, peerNonce);
            if (exists) {
                shouldSkip[index] = true;
            }
        }

        // Count how many releases we will record
        for (uint256 i = 0; i < inboundAwaitingPeerReleaseNonces.length; i++) {
            if (!shouldSkip[i]) inboundReleasedCount++;
        }

        // Allocate result array and record releases
        result.inboundReleasedByPeer = new uint256[](inboundReleasedCount);
        uint256 inboundReleasedIndex = 0;

        for (uint256 i = 0; i < inboundAwaitingPeerReleaseNonces.length; i++) {
            // If NOT in their outbound tracker anymore, the peer released it - finalize locally
            if (!shouldSkip[i]) {
                uint256 nonce = inboundAwaitingPeerReleaseNonces[i];
                recordPeerRelease(inboundTracker, nonce);
                result.inboundReleasedByPeer[inboundReleasedIndex++] = nonce;
            }
        }

        return result;
    }

    // ============================================
    // Overlap Calculation Functions
    // ============================================

    /**
     * @notice Calculate overlap amount between two nonce lists
     * @dev Used to calculate true assets in-transit by removing double-counted amounts
     *
     * Finds nonces that appear in both lists (tracked locally and reported by peer)
     * and sums their amounts from tracker. This prevents double-counting when both
     * sides count the same assets.
     *
     * @param tracker The operation tracker to get amounts from
     * @param theirNonces Nonces reported by peer for receipt
     * @return total Sum of amounts for overlapping nonces
     */
    function calculateOverlapAmount(
        State storage tracker,
        uint256[] memory theirNonces
    )
        public
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < theirNonces.length; i++) {
            Sent storage op = tracker.operations[theirNonces[i]];
            if (op.timestamp != 0 && !op.peerReceiptRecorded) {
                total += op.amount;
            }
        }
    }

    /**
     * @notice Calculate inbound overlap constrained by a peer snapshot timestamp
     * @dev Counts received operations that the peer still considered outbound at snapshot time
     * @param inboundTracker The inbound state tracker (operations we received)
     * @param snapshotTime Peer snapshot timestamp used for causality checks
     * @param peerOutboundNonces Nonces the peer reported as still outbound at snapshot time
     * @return total Sum of overlapping amounts to subtract from peer reported assets
     */
    function calculateInboundOverlap(
        State storage inboundTracker,
        uint256 snapshotTime,
        uint256[] memory peerOutboundNonces
    )
        public
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < peerOutboundNonces.length; i++) {
            uint256 nonce = peerOutboundNonces[i];
            Received storage op = inboundTracker.receivedOperations[nonce];

            if (op.sentAt != 0 && op.sentAt <= snapshotTime) {
                total += op.amount;
            }
        }
    }

    /**
     * @notice Check if a received operation exists
     * @param state The inbound tracker state
     * @param nonce Nonce to inspect
     * @return True if the received operation has been recorded
     */
    function hasReceivedOperation(State storage state, uint256 nonce) public view returns (bool) {
        return state.receivedOperations[nonce].receivedAt != 0;
    }

    /**
     * @notice Check if a received operation is still waiting on peer release
     * @param state The inbound tracker state
     * @param nonce Nonce to inspect
     * @return True if recorded and the peer has not yet released it
     */
    function isInboundAwaitingPeerRelease(State storage state, uint256 nonce) public view returns (bool) {
        Received storage op = state.receivedOperations[nonce];
        return op.receivedAt != 0 && !op.peerReleased;
    }

    /**
     * @notice Sum received amounts initiated after a peer snapshot timestamp
     * @dev Used to compensate for snapshot staleness when peer sends after reporting assets
     * @param inboundTracker The inbound state tracker (operations we received)
     * @param snapshotTime Peer snapshot timestamp
     * @return total Total amount of receives initiated after the snapshot
     */
    function sumReceivesAfter(State storage inboundTracker, uint256 snapshotTime) public view returns (uint256 total) {
        uint256 pendingLength = inboundTracker.inboundAwaitingPeerRelease.length;
        for (uint256 i = 0; i < pendingLength; i++) {
            uint256 nonce = inboundTracker.inboundAwaitingPeerRelease[i];
            Received storage op = inboundTracker.receivedOperations[nonce];

            if (op.sentAt > snapshotTime) {
                total += op.amount;
            }
        }
    }

    // ============================================
    // Awaiting Asset Notification Queue
    // ============================================

    /**
     * @notice Add a bridge notification that is awaiting asset delivery
     * @dev Called when SYNC_BRIDGED message arrives but assets haven't arrived yet
     * @param queue The notification queue
     * @param notification The bridge notification from peer
     */
    function addAwaitingAssetNotification(
        PendingBridgedQueue storage queue,
        RunespearProtocol.Bridged memory notification
    )
        public
    {
        // Check if already exists (idempotent)
        if (queue.notifications[notification.nonce].nonce != 0) {
            return; // Already pending
        }

        // Store notification
        queue.notifications[notification.nonce] = notification;

        // Add to awaiting-asset array if not already there
        bool alreadyPending = false;
        for (uint256 i = 0; i < queue.awaitingAssetNonces.length; i++) {
            if (queue.awaitingAssetNonces[i] == notification.nonce) {
                alreadyPending = true;
                break;
            }
        }

        if (!alreadyPending) {
            queue.awaitingAssetNonceIndex[notification.nonce] = queue.awaitingAssetNonces.length;
            queue.awaitingAssetNonces.push(notification.nonce);
        }
    }

    /**
     * @notice Remove an awaiting-asset notification from the queue
     * @dev Called after successfully processing a notification
     * @param queue The notification queue
     * @param nonce The nonce to remove
     */
    function removeAwaitingAssetNotification(PendingBridgedQueue storage queue, uint256 nonce) public {
        // Delete notification
        delete queue.notifications[nonce];

        // Always do linear search to be safe (less efficient but more robust)
        // awaitingAssetNonces should be small in practice
        // This prevents issues when index mapping becomes stale after swap operations
        for (uint256 i = 0; i < queue.awaitingAssetNonces.length; i++) {
            if (queue.awaitingAssetNonces[i] == nonce) {
                _removeAwaitingAssetNotificationByIndex(queue, i);
                break;
            }
        }
    }

    /**
     * @notice Remove awaiting-asset notification by array index
     * @param queue The notification queue
     * @param index Index in awaitingAssetNonces array
     */
    function _removeAwaitingAssetNotificationByIndex(PendingBridgedQueue storage queue, uint256 index) private {
        if (index >= queue.awaitingAssetNonces.length) return;

        uint256 lastIndex = queue.awaitingAssetNonces.length - 1;
        uint256 nonceToRemove = queue.awaitingAssetNonces[index];

        // Swap with last element if not already last
        if (index != lastIndex) {
            uint256 lastNonce = queue.awaitingAssetNonces[lastIndex];
            queue.awaitingAssetNonces[index] = lastNonce;
            queue.awaitingAssetNonceIndex[lastNonce] = index;
        }

        // Remove last element and clean up index mapping
        queue.awaitingAssetNonces.pop();
        delete queue.awaitingAssetNonceIndex[nonceToRemove];
    }

    /**
     * @notice Get an awaiting-asset notification
     * @param queue The notification queue
     * @param nonce The nonce to look up
     * @return exists Whether notification exists
     * @return notification The notification (empty if doesn't exist)
     */
    function getAwaitingAssetNotification(
        PendingBridgedQueue storage queue,
        uint256 nonce
    )
        public
        view
        returns (bool exists, RunespearProtocol.Bridged memory notification)
    {
        notification = queue.notifications[nonce];
        exists = notification.nonce != 0;
    }

    /**
     * @notice Get all nonces awaiting asset delivery
     * @param queue The notification queue
     * @return Array of awaiting-asset nonces
     */
    function getAwaitingAssetNonces(PendingBridgedQueue storage queue) public view returns (uint256[] memory) {
        return queue.awaitingAssetNonces;
    }

    /**
     * @notice Check if awaiting-asset notification queue is empty
     * @param queue The notification queue
     * @return True if no pending notifications
     */
    function isPendingQueueEmpty(PendingBridgedQueue storage queue) public view returns (bool) {
        return queue.awaitingAssetNonces.length == 0;
    }

    /**
     * @notice Get count of awaiting-asset notifications
     * @param queue The notification queue
     * @return Number of awaiting-asset notifications
     */
    function getAwaitingAssetCount(PendingBridgedQueue storage queue) public view returns (uint256) {
        return queue.awaitingAssetNonces.length;
    }
}
