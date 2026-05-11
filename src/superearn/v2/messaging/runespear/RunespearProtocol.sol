// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { SuperEarnV2Protocol } from "../SuperEarnV2Protocol.sol";

/**
 * @title RunespearProtocol
 * @notice Protocol definitions for Runespear crosschain messaging with bridge tracking
 * @dev Contains message envelope and bridge tracking structures used across adapters
 *
 * ## Purpose
 * This library separates Runespear-specific messaging structures from application-level
 * protocol definitions (SuperEarnV2Protocol). It enables:
 * - Reusable bridge tracking patterns
 * - Message envelope standard for piggybacking state
 * - Clean separation between messaging infrastructure and business logic
 *
 * ## Pattern
 * All Runespear messages are wrapped in RunespearMessageEnvelope:
 * ```
 * envelope = RunespearMessageEnvelope({
 *     payload: abi.encode(yourMessage),
 *     bridgeState: adapter.getCurrentBridgeState()
 * });
 * ```
 *
 * This enables:
 * 1. Automatic bridge state synchronization on every message
 * 2. Overlap calculation for preventing double-counting
 * 3. Reconciliation without dedicated sync messages
 */
library RunespearProtocol {
    // ============================================
    // Bridge Tracking Structures
    // ============================================

    /**
     * @notice Bridge sent notification payload
     * @param nonce Unique nonce identifying the bridge operation
     * @param assetType Type of asset being bridged (USDC or USDT)
     * @param amount Amount of assets bridged (expected amount at destination)
     * @param sourceChainId Chain ID where bridge was initiated
     * @param timestamp When the bridge was initiated on source chain (block.timestamp)
     * @dev Sent from source adapter when bridge is initiated
     * @dev Using AssetType instead of token address to avoid confusion between source/dest chain tokens
     * @dev timestamp is critical for causality: determines if bridge was sent before/after peer snapshots
     */
    struct Bridged {
        uint256 nonce;
        SuperEarnV2Protocol.AssetType assetType;
        uint256 amount;
        uint256 sourceChainId;
        uint256 timestamp;
    }

    /**
     * @notice Bridge state snapshot for state sharing between adapters
     * @dev Contains current bridge operations state at a point in time
     * @param totalOutboundAwaitingPeerReceipt Total amount in outbound tracker (sent, awaiting peer receipt)
     * @param totalOutboundAwaitingPeerReceipt Total amount currently outbound awaiting peer receipt confirmation
     * @param totalInboundAwaitingPeerRelease Total amount received but not yet released by the peer
     * @param outboundAwaitingPeerReceipt Nonces of sent operations awaiting peer receipt
     * @param inboundAwaitingPeerRelease Nonces of received operations awaiting peer release
     * @param timestamp When this state snapshot was taken
     */
    struct BridgeState {
        uint256 totalOutboundAwaitingPeerReceipt;
        uint256 totalInboundAwaitingPeerRelease;
        uint256[] outboundAwaitingPeerReceipt;
        uint256[] inboundAwaitingPeerRelease;
        uint256 timestamp;
    }

    /**
     * @notice Runespear message envelope wrapping all messages with complete state snapshot
     * @dev Every Runespear message includes full vault and bridge state for synchronization
     *
     * ## Universal State Piggybacking Pattern
     *
     * Instead of dedicated sync messages, we piggyback complete state on EVERY message:
     * - Sender includes current StateSnapshot (vault + bridge state) in envelope
     * - Receiver extracts and updates peer state
     * - Both sides maintain synchronized view of each other's complete state
     *
     * Benefits:
     * - Single source of truth for state synchronization
     * - No redundant bridge state encoding
     * - Automatic reconciliation on every interaction
     * - Enables accurate overlap calculation with synchronized timestamps
     * - Eliminates SYNC_NOOP as special case (becomes no-op SYNC)
     *
     * @param payload Original message payload (deposit amount, withdrawal amount, etc.)
     * @param stateSnapshot Complete state snapshot (vault + bridge state) at message send time
     */
    struct RunespearMessageEnvelope {
        bytes payload;
        SuperEarnV2Protocol.StateSnapshot stateSnapshot;
    }

    /// @notice Version salt for correct coordination
    bytes32 private constant VERSION_SALT = keccak256("RUNESPEAR_V1");

    /// @notice General state synchronization request message (with state always in envelope)
    bytes4 public constant REQUEST_SYNC = bytes4(keccak256(abi.encodePacked("requestSync()", VERSION_SALT)));

    // @notice State synchronization with no expectation for acknowledgement (mostly for state synchronization)
    bytes4 public constant SYNC_NOOP = bytes4(keccak256(abi.encodePacked("sync()", VERSION_SALT)));

    /// @notice Notification that bridge was initiated (sent from source to destination).
    bytes4 public constant SYNC_BRIDGED = bytes4(keccak256(abi.encodePacked("bridgeSent(Bridged)", VERSION_SALT)));
}
