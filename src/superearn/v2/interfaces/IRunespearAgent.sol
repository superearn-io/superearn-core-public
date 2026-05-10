// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { RunespearProtocol } from "../messaging/runespear/RunespearProtocol.sol";

/**
 * @title IRunespearAgent
 * @notice Interface for Runespear message routing agents
 * @dev Enables complete separation of crosschain orchestration from vaults and adapters
 *
 * ## Purpose
 * This interface externalizes ALL crosschain logic from vaults, making them pure state machines.
 * The agent orchestrates both inbound and outbound crosschain operations.
 *
 * ## Architecture
 * - **Vault**: Pure state machine, no crosschain awareness
 * - **Adapter**: Bridge accounting + temporary custody
 * - **Agent**: Crosschain orchestration for both inbound and outbound
 *
 * ## Inbound Flow (peer → local)
 * 1. Adapter receives CCIP message
 * 2. Adapter forwards to agent.handle()
 * 3. Agent routes to appropriate vault handler
 *
 * ## Outbound Flow (local → peer)
 * 1. Vault calls agent
 * 2. Agent orchestrates adapter operations
 * 3. Adapter executes CCIP send
 *
 * ## Benefits
 * 1. **Complete Isolation**: Vaults have ZERO crosschain awareness
 * 2. **Symmetry**: Both inbound and outbound go through agent
 * 3. **Modularity**: Routing logic completely separated
 * 4. **Upgradability**: Swap agents without touching vaults/adapters
 */
interface IRunespearAgent {
    // ============================================
    // Inbound Message Handling
    // ============================================

    /**
     * @notice Handle incoming Runespear message from adapter
     * @dev Called by CrosschainAdapter when a CCIP message arrives
     *
     * The agent is responsible for:
     * 1. Decoding the message payload
     * 2. Updating peer bridge state (via adapter)
     * 3. Routing to appropriate vault handlers based on predicate
     * 4. Handling any errors or unknown predicates
     *
     * @param sourceChainId Chain ID where message originated
     * @param predicate Message predicate (e.g., WITHDRAW)
     * @param args Raw encoded message arguments (still in envelope format)
     * @param messageId CCIP message ID for tracking
     * @param envelope Decoded message envelope containing payload and bridge state
     */
    function delegate(
        uint256 sourceChainId,
        bytes4 predicate,
        bytes memory args,
        bytes32 messageId,
        RunespearProtocol.RunespearMessageEnvelope calldata envelope
    )
        external;

    // ============================================
    // Outbound Message Operations
    // ============================================

    /**
     * @notice Send message to peer vault
     * @dev Called by local vault to send crosschain message
     *      Agent orchestrates: vault → agent → adapter → CCIP
     *
     * @param predicate Message type (e.g., WITHDRAW, DEPOSIT, etc.)
     * @param payload Encoded message payload
     */
    function sendMessage(bytes4 predicate, bytes memory payload) external;

    /**
     * @notice Prepare and send assets (complete flow with agent custody)
     * @dev Vault transfers to agent, agent approves adapter, agent calls adapter
     *      Flow: Vault → Agent (transfer) → Agent approves Adapter → Adapter.sendAssets()
     *
     * This achieves complete adapter isolation - vault only knows agent.
     * Agent has temporary custody during the transaction.
     *
     * @param asset Asset address to bridge
     * @param amount Amount to bridge
     * @return nonce Bridge operation nonce for tracking
     */
    function prepareAndSendAssets(address asset, uint256 amount) external returns (uint256 nonce);

    // ============================================
    // Inbound Callbacks (Adapter → Agent → Vault)
    // ============================================

    /**
     * @notice Send bridged assets to vault
     * @dev Called by adapter when bridge delivers assets
     *      Agent pulls from adapter, transfers to vault
     *      Flow: Adapter → Agent (pull) → Vault (push) → Vault.onBridgeReceived()
     *
     * @param targetVault Vault to receive assets and notification
     * @param nonce Bridge operation nonce
     * @param token Token received
     * @param amount Amount received
     * @param sourceChainId Source chain ID
     */
    function sendBridgedAssets(
        address targetVault,
        uint256 nonce,
        address token,
        uint256 amount,
        uint256 sourceChainId
    )
        external;

    // ============================================
    // Query Operations
    // ============================================

    /**
     * @notice Get assets currently in transit to peer
     * @dev Vault calls this for totalAssets calculation
     * @return Amount of assets in transit
     */
    function getAssetsInTransit() external view returns (uint256);

    /**
     * @notice Get true peer assets (with overlap removed)
     * @dev Vault calls this for remoteAssets calculation
     *      Agent gets report from adapter, resolves asset type, and returns amount + decimals
     * @return assets True peer assets (reported minus overlap)
     * @return assetDecimals Decimals of the reported asset (resolved via assetType)
     */
    function getTruePeerAssets() external view returns (uint256 assets, uint8 assetDecimals);
}
