// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { SuperEarnV2Protocol } from "../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../messaging/runespear/RunespearProtocol.sol";
import { ICrosschainVault } from "./ICrosschainVault.sol";
import { IRunespearAgent } from "./IRunespearAgent.sol";

/**
 * @title ICrosschainAdapter
 * @notice Interface for crosschain bridge adapter with universal state synchronization.
 * @dev Messages and token settlements are asynchronous; the adapter keeps both streams reconciled and
 *      exposes minimal hooks so vaults remain deterministic.
 *
 * ## Universal State Piggybacking
 * Every Runespear message carries a complete StateSnapshot (VaultState + BridgeState)
 * in the envelope, enabling automatic state synchronization without dedicated sync messages.
 */
interface ICrosschainAdapter {
    // ============================================
    // Events
    // ============================================

    event AssetsSent(
        uint256 indexed nonce,
        address indexed token,
        uint256 amount,
        address indexed destinationVault,
        uint256 destinationChainId
    );

    event AssetsReceived(
        uint256 indexed nonce, address indexed token, uint256 amount, address indexed sourceVault, uint256 sourceChainId
    );

    event BridgeDepositAddressSet(address indexed depositAddress);

    event AwaitingAssetNotificationAdded(
        uint256 indexed nonce, address indexed token, uint256 amount, uint256 sourceChainId
    );
    event BridgeReceiptForced(uint256 indexed nonce, address indexed token, uint256 amount, uint256 sourceChainId);
    event AwaitingAssetNotificationsProcessed(uint256 processedCount, uint256 remainingCount);

    event PeerConfigured(uint256 indexed chainId, address indexed peerVault, address indexed localVault, bool isOrigin);

    event AgentSet(address indexed agent);
    event AccountantSet(address indexed accountant);
    event LocalVaultRoleSet(ICrosschainVault.VaultRole role);

    event TokenSwept(address indexed token, address indexed recipient, uint256 amount);
    event EthSwept(address indexed recipient, uint256 amount);

    // ============================================
    // Errors
    // ============================================

    error InvalidBridgeAddress();
    error InvalidVault();

    // ============================================
    // Core Bridge Functions
    // ============================================

    /**
     * @notice Send assets to bridge (called by vault)
     * @param token Token address to bridge
     * @param amount Amount to send
     * @param destinationChainId Destination chain ID
     * @return nonce Unique nonce for tracking
     */
    function sendAssets(address token, uint256 amount, uint256 destinationChainId) external returns (uint256 nonce);

    /**
     * @notice Callback from bridge when assets arrive (called by bridge)
     * @param nonce Unique nonce from source chain
     * @param token Token address received
     * @param amount Amount received
     * @param sourceChainId Source chain ID
     * @param sentAt Timestamp when assets were sent from source chain
     */
    function onBridgeReceived(
        uint256 nonce,
        address token,
        uint256 amount,
        uint256 sourceChainId,
        uint256 sentAt
    )
        external;

    /**
     * @notice Force processing of a bridge receipt when automation fails
     * @param operationNonce Unique nonce from source chain being settled
     * @param token Destination-chain token address received for this nonce
     * @param expectedAmount Amount that arrived on this chain (validated against adapter balance)
     * @param sourceChainId Source chain ID for auditing
     */
    function forceProcessBridgeReceipt(
        uint256 operationNonce,
        address token,
        uint256 expectedAmount,
        uint256 sourceChainId
    )
        external;

    /**
     * @notice Process pending bridge assets
     * @dev Called by keeper to process any pending bridge receipts
     *      Can be called regularly (scheduled) or ad-hoc
     */
    function processPendingBridgeAssets() external;

    // Note: Confirmation functions removed - handled automatically by adapter

    // ============================================
    // Configuration Functions
    // ============================================

    /**
     * @notice Set bridge deposit address
     * @param depositAddress Address to send tokens for bridging
     */
    function setBridgeDepositAddress(address depositAddress) external;

    /**
     * @notice Set local vault address that can call sendAssets
     * @dev Vault must implement ICrosschainVault and expose a static vaultRole()
     * @param vault Vault address (origin or remote)
     */
    function setVault(address vault) external;

    /**
     * @notice Explicitly configure the local vault role for this adapter.
     * @param role Role of the local vault
     */
    function setLocalVaultRole(ICrosschainVault.VaultRole role) external;

    /**
     * @notice Set the outbound bridge nonce pointer
     * @dev Governance hook to realign nonce after migrations; forwards to accountant
     * @param newNonce New nonce value (must not decrease current)
     */
    function setBridgeNonce(uint256 newNonce) external;

    /**
     * @notice Configure peer vault and chain for crosschain communication
     * @param chainId Chain ID of peer
     * @param chainSelector CCIP chain selector for peer
     * @param peerVault Address of peer vault on other chain
     * @param localVault Address of local vault (origin or remote)
     * @param gasLimit Gas limit for messages to peer
     * @param isOrigin Whether the peer is an origin vault
     */
    function configurePeer(
        uint256 chainId,
        uint64 chainSelector,
        address peerVault,
        address peerAdapter,
        address localVault,
        uint256 gasLimit,
        bool isOrigin
    )
        external;

    /**
     * @notice Send message to peer vault
     * @dev Only callable by vaults; wraps payload in envelope with complete state snapshot
     *      Automatically includes current VaultState + BridgeState in every message
     * @param destinationChainId Destination chain ID
     * @param predicate Message predicate
     * @param args Encoded message arguments (payload only, state in envelope)
     * @return messageId CCIP message ID
     */
    function sendMessage(
        uint256 destinationChainId,
        bytes4 predicate,
        bytes memory args
    )
        external
        returns (bytes32 messageId);

    // ============================================
    // View Functions
    // ============================================

    function bridgeDepositAddress() external view returns (address);

    /// @notice Get local vault address (Origin or Remote)
    function vault() external view returns (address);

    /// @notice Get the configured role of the local vault
    function localVaultRole() external view returns (ICrosschainVault.VaultRole);

    /// @notice Get the chain ID of the peer vault
    function getPeerChainId() external view returns (uint256);

    function peerAdapter() external view returns (address);

    /// @notice Get bridge accountant address
    /// @dev All accounting functions (assetsInTransit*, calculate*, getPeerReportedAssets, etc.) are now on the
    /// accountant
    function accountant() external view returns (address);

    /// @notice Get origin chain ID
    function originChainId() external view returns (uint256);

    /// @notice Get remote chain ID
    function remoteChainId() external view returns (uint256);

    /// @notice Get peer vault address (informational only)
    function peerVault() external view returns (address);

    /// @notice Get message agent address
    function agent() external view returns (IRunespearAgent);

    /// @notice Resolve token address mapped to a given asset type
    function assetTypeToToken(SuperEarnV2Protocol.AssetType assetType) external view returns (address);

    /// @notice Set the token address for a specific asset type
    /// @param assetType The asset type to map
    /// @param token The token address to map to the asset type
    function setAssetTypeToken(SuperEarnV2Protocol.AssetType assetType, address token) external;

    /// @notice Set message routing agent
    function setAgent(address agent) external;

    // ============================================
    // State Snapshot Management
    // ============================================

    /**
     * @notice Send a SYNC_NOOP message to peer
     * @dev Sends a state sync message with no operation
     */
    function sendSyncNoop() external;

    // ============================================
    // Defensive Message Retry Functions
    // ============================================

    /**
     * @notice Retry a specific failed message
     * @param messageId CCIP message ID to retry
     * @dev Available for both owner and managers (keepers)
     */
    function retryFailedMessage(bytes32 messageId) external;

    /**
     * @notice Remove a failed message from storage (manual cleanup)
     * @param messageId CCIP message ID to remove
     * @dev Owner-only function (permanent removal)
     */
    function removeFailedMessage(bytes32 messageId) external;

    // ============================================
    // Rescue Functions
    // ============================================

    /**
     * @notice Sweep excess tokens that are not required for bridge settlement
     * @param token Token to sweep
     * @param to Recipient address
     * @param amount Amount to sweep (use type(uint256).max to sweep all available)
     */
    function sweepToken(address token, address to, uint256 amount) external;

    /**
     * @notice Returns the amount of a token that can be swept safely
     * @param token Token address to inspect
     * @return Amount available for sweeping
     */
    function sweepableBalance(address token) external view returns (uint256);

    /**
     * @notice Sweep native ETH from the adapter
     * @param to Recipient address
     * @param amount Amount to sweep (use type(uint256).max to sweep all available)
     */
    function sweepEth(address to, uint256 amount) external;
}
