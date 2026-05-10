// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { RunespearTransceiver } from "@runespear/RunespearTransceiver.sol";
import { SuperEarnV2Protocol } from "../../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../../messaging/runespear/RunespearProtocol.sol";
import { ICrosschainAdapter } from "../../interfaces/ICrosschainAdapter.sol";
import { ICrosschainVault } from "../../interfaces/ICrosschainVault.sol";
import { IRunespearAgent } from "../../interfaces/IRunespearAgent.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { BridgeQueue } from "./BridgeQueue.sol";
import { VaultStateHelper } from "../../libraries/VaultStateHelper.sol";
import { IBridgeAccountant } from "../../interfaces/IBridgeAccountant.sol";
import { SuperEarnAccessControl } from "../../base/SuperEarnAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IAccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { CCIPReceiverUpgradeable } from "../../messaging/ccip/CCIPReceiverUpgradeable.sol";

/**
 * @title CrosschainAdapter
 * @notice Centralizes cross-chain messaging and bridge custody for a single vault.
 * @dev Sole entry point for CCIP/Runespear traffic, bridge callbacks, and manual overrides.
 *
 * ## Architectural principles
 *
 * ### 1. Single cross-chain surface area
 * - Receives every CCIP/Runespear message destined for the vault.
 * - Forwards application payloads to the agent after reconciling bridge state.
 * - Sends outbound envelopes on behalf of the vault via `sendMessage`.
 * - Orchestrates bridge deposits and receipts while delegating accounting to `BridgeAccountant`.
 *
 * ### 2. Deterministic vaults
 * - Origin/remote vault contracts never talk cross-chain directly.
 * - Vault state machines remain chain-local; this adapter handles all non-deterministic effects.
 * - Vault entry points are restricted to pre-approved callers (agent or managers).
 *
 * ### 3. Universal state piggybacking
 * - Every outbound envelope includes a `StateSnapshot` (vault + bridge state captured atomically).
 * - The adapter refreshes `peerSnapshot` on every inbound message before any business logic runs.
 * - Overlap calculations always use the snapshot timestamp to avoid double-counting assets.
 *
 * ### 4. Message flow summary
 * - **Outbound:** vault/agent → `sendMessage` → wrap payload + snapshot → CCIP to peer adapter.
 * - **Inbound:** CCIP router → `_handle` → decode + snapshot update → optional bridge handling → agent delegate.
 *
 * ### 5. Dual pending-nonce tracking
 * - Outbound queue (`_outboundTracker`): nonces we initiated awaiting peer acknowledgement.
 * - Inbound queue (`_awaitingAssetQueue` + reservations): notifications from the peer waiting on asset delivery.
 * - Separate queues keep CCIP timing races from corrupting balances and highlight stuck operations.
 *
 * ### 6. Explicit async handling
 * - CCIP/Runespear messages and bridge deliveries are fully asynchronous; either side can arrive first.
 * - Pending queues reconcile the two streams without losing causality.
 * - Keepers must call `processPendingBridgeAssets` before acting on balances to flush late arrivals.
 */
contract CrosschainAdapter is
    Initializable,
    ICrosschainAdapter,
    RunespearTransceiver,
    SuperEarnAccessControl,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ============================================
    // Errors
    // ============================================

    error InvalidToken();
    error ZeroAmount();
    error InsufficientBridgedAmount();
    error UnknownPredicate();
    error OnlyAgent();
    error InvalidAgent();
    error InvalidAddress();
    error InvalidPeerAdapter();
    error InsufficientSweepableBalance(uint256 requested, uint256 available);
    error TransferFailed();
    error LocalVaultRoleNotSet();
    error LocalVaultRoleConflict(ICrosschainVault.VaultRole current, ICrosschainVault.VaultRole attempted);
    error PeerAlreadyConfigured(uint256 existingChainId, uint256 attemptedChainId);
    error NotImplemented();
    error DuplicateMessageSent();
    error InvalidPredicate();

    // ============================================
    // State Variables
    // ============================================

    // Vault Routing
    address public vault; // Local vault address (Origin or Remote)

    uint256 public originChainId;
    uint256 public remoteChainId;

    // Peer vault address (informational only, never called directly)
    address public peerVault;

    // Intermediary agent that communicates with the vault
    IRunespearAgent public agent;

    /// @dev Rhino.fi Smart Deposit Address
    ///      Tokens deposited to this addressed are bridged by Rhino to
    ///      the peer CrosschainAdapter, which will process bridging/accounting
    ///      and then transfer the processed amount to the peer Vault
    address public bridgeDepositAddress;

    // prevent multiple messages sent within the same block
    uint256 private lastMessageSentAt;

    // Single peer adapter address (single-peer design)
    address public peerAdapter;

    // Local vault metadata
    ICrosschainVault.VaultRole private _localVaultRole;
    bool private _localVaultRoleConfigured;

    // Asset Type Mapping
    mapping(SuperEarnV2Protocol.AssetType => address) public assetTypeToToken;

    // Access control is provided by SuperEarnAccessControl; manager-only entry points rely on MANAGEMENT_ROLE.

    // ============================================
    // Bridge Accounting
    // ============================================

    /// @notice Bridge accountant that handles all bridge tracking and calculations
    /// @dev Separates accounting logic from adapter infrastructure
    ///      Adapter delegates all accounting operations to this contract
    IBridgeAccountant private immutable _accountant;

    /// @notice The only token allowed for bridge operations
    /// @dev Set at construction time. Used for validation only.
    address public immutable bridgeToken;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address accountantAddr, address _bridgeToken) {
        if (accountantAddr == address(0)) revert InvalidAddress();
        if (_bridgeToken == address(0)) revert InvalidToken();
        _accountant = IBridgeAccountant(accountantAddr);
        bridgeToken = _bridgeToken;
        _disableInitializers();
    }

    /// @notice Get bridge accountant address
    /// @return Address of the bridge accountant
    function accountant() external view override returns (address) {
        return address(_accountant);
    }

    // ============================================
    // Initializer
    // ============================================

    /**
     * @notice Initialize the crosschain adapter
     * @param _router CCIP router address
     * @param _feeToken Fee token address (address(0) for native)
     * @param _vault Local vault address (Origin or Remote)
     * @param _owner Owner address that will receive GOVERNANCE_ROLE
     * @dev Note: RunespearTransceiver constructor must be called separately if it's not upgradeable
     */
    function initialize(address _router, address _feeToken, address _vault, address _owner) public initializer {
        __RunespearTransceiver_init(_router, _feeToken);
        __SuperEarnAccessControl_init();
        __ReentrancyGuard_init();

        if (_vault == address(0)) revert InvalidVault();
        if (_owner == address(0)) revert InvalidAddress();

        _assignVault(_vault);

        // Grant GOVERNANCE_ROLE to owner
        _grantRole(GOVERNANCE_ROLE, _owner);
    }

    // ============================================
    // Vault Role Helpers
    // ============================================

    function localVaultRole() public view override returns (ICrosschainVault.VaultRole) {
        if (!_localVaultRoleConfigured) revert LocalVaultRoleNotSet();
        return _localVaultRole;
    }

    /**
     * @notice Get the chain ID of the peer vault
     * @return Chain ID where the peer vault is deployed
     */
    function getPeerChainId() public view override returns (uint256) {
        ICrosschainVault.VaultRole role = localVaultRole();
        return role == ICrosschainVault.VaultRole.Origin ? remoteChainId : originChainId;
    }

    function setLocalVaultRole(ICrosschainVault.VaultRole role) external override onlyGovernance {
        _setLocalVaultRole(role);
    }

    function _setLocalVaultRole(ICrosschainVault.VaultRole role) internal {
        if (_localVaultRoleConfigured) {
            if (_localVaultRole != role) {
                revert LocalVaultRoleConflict(_localVaultRole, role);
            }
            return;
        }

        _localVaultRole = role;
        _localVaultRoleConfigured = true;
        emit LocalVaultRoleSet(role);
    }

    function _assignVault(address _vault) internal {
        if (_vault == address(0)) revert InvalidVault();

        ICrosschainVault.VaultRole role;
        try ICrosschainVault(_vault).vaultRole() returns (ICrosschainVault.VaultRole detected) {
            role = detected;
        } catch {
            revert InvalidVault();
        }

        vault = _vault;
        _setLocalVaultRole(role);
    }

    function setBridgeDepositAddress(address depositAddress) external override onlyGovernance {
        if (depositAddress == address(0)) revert InvalidAddress();
        bridgeDepositAddress = depositAddress;
        emit BridgeDepositAddressSet(depositAddress);
    }

    function setVault(address _vault) external override onlyGovernance {
        _assignVault(_vault);
    }

    function setBridgeNonce(uint256 newNonce) external override onlyGovernance {
        _accountant.forceSetOutboundNonce(newNonce);
    }

    function setAssetTypeToken(SuperEarnV2Protocol.AssetType assetType, address tokenAddress) external onlyGovernance {
        if (tokenAddress == address(0)) revert InvalidToken();
        assetTypeToToken[assetType] = tokenAddress;
    }

    function setAgent(address _agent) external override onlyGovernance {
        if (_agent == address(0)) revert InvalidAgent();
        agent = IRunespearAgent(_agent);
        emit AgentSet(_agent);
    }

    /**
     * @notice Configure peer vault and chain for crosschain communication
     * @param chainId Chain ID of peer
     * @param chainSelector CCIP chain selector for peer
     * @param peerVaultAddr Address of peer vault on other chain (informational)
     * @param peerAdapterAddr Address of peer adapter on other chain
     * @param localVault Address of local vault (origin or remote)
     * @param gasLimit Gas limit for messages to peer
     * @param isOrigin Whether the peer is an origin vault
     * @dev This replaces the individual configureRemoteVault/configureOrigin functions
     */
    function configurePeer(
        uint256 chainId,
        uint64 chainSelector,
        address peerVaultAddr,
        address peerAdapterAddr,
        address localVault,
        uint256 gasLimit,
        bool isOrigin
    )
        external
        override
        onlyGovernance
    {
        if (chainId == 0) revert InvalidChainId();
        if (peerVaultAddr == address(0)) revert InvalidPeer();
        if (peerAdapterAddr == address(0)) revert InvalidPeer();
        if (localVault == address(0)) revert InvalidVault();

        // Set local vault and synchronize role from the contract itself
        _assignVault(localVault);

        ICrosschainVault.VaultRole expectedRole =
            isOrigin ? ICrosschainVault.VaultRole.Remote : ICrosschainVault.VaultRole.Origin;
        if (_localVaultRole != expectedRole) {
            revert LocalVaultRoleConflict(_localVaultRole, expectedRole);
        }

        // Enforce single peer: if already configured, only allow the same chain to be reconfigured
        uint256 existingPeerChainId = originChainId != 0 ? originChainId : remoteChainId;
        if (existingPeerChainId != 0 && existingPeerChainId != chainId) {
            revert PeerAlreadyConfigured(existingPeerChainId, chainId);
        }

        // Store peer vault address (informational only, never called)
        peerVault = peerVaultAddr;

        // Set chain IDs based on type
        if (isOrigin) {
            // Local is remote, peer is origin
            originChainId = chainId;
        } else {
            // Local is origin, peer is remote
            remoteChainId = chainId;
        }

        // Store peer adapter address (for CCIP messaging)
        peerAdapter = peerAdapterAddr;

        // Configure bidirectional chain for CCIP messaging (whitelist adapter as sender)
        _configureBidirectionalChain(chainId, chainSelector, peerAdapterAddr, gasLimit);

        emit PeerConfigured(chainId, peerVaultAddr, localVault, isOrigin);
    }

    // ============================================
    // Asset Type Resolution
    // ============================================

    function _getAssetType(address token) internal view returns (SuperEarnV2Protocol.AssetType) {
        if (token == assetTypeToToken[SuperEarnV2Protocol.AssetType.USDC]) {
            return SuperEarnV2Protocol.AssetType.USDC;
        }
        if (token == assetTypeToToken[SuperEarnV2Protocol.AssetType.USDT]) {
            return SuperEarnV2Protocol.AssetType.USDT;
        }
        revert InvalidToken();
    }

    function _resolveAssetTypeToToken(SuperEarnV2Protocol.AssetType assetType) internal view returns (address token) {
        token = assetTypeToToken[assetType];
        if (token == address(0)) revert InvalidToken();
        return token;
    }

    // ============================================
    // Core Bridge Functions
    // ============================================

    /// @dev Outbound bridge flow:
    ///      1. Allocate a new nonce with the accountant.
    ///      2. Move funds into the configured bridge deposit address.
    ///      3. Notify the agent so vault-side bookkeeping can react.
    function sendAssets(
        address token,
        uint256 amount,
        uint256 destinationChainId
    )
        external
        override
        returns (uint256 latestOutboundNonce)
    {
        if (msg.sender != address(agent)) {
            revert UnauthorizedCaller();
        }

        if (block.timestamp == lastMessageSentAt) {
            revert DuplicateMessageSent();
        }
        lastMessageSentAt = block.timestamp;

        if (token == address(0)) revert InvalidToken();
        if (token != bridgeToken) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        if (bridgeDepositAddress == address(0)) revert InvalidAddress();

        latestOutboundNonce = _accountant.allocateOutboundNonce(amount);

        IERC20(token).safeTransferFrom(address(agent), bridgeDepositAddress, amount);

        // Single-peer design: destination must match configured peer chain
        if (destinationChainId != getPeerChainId()) revert InvalidPeerAdapter();
        if (peerAdapter == address(0)) revert InvalidPeerAdapter();

        SuperEarnV2Protocol.AssetType assetType = _getAssetType(token);

        RunespearProtocol.Bridged memory bridged = RunespearProtocol.Bridged({
            nonce: latestOutboundNonce,
            assetType: assetType,
            amount: amount,
            sourceChainId: block.chainid,
            timestamp: block.timestamp
        });

        SuperEarnV2Protocol.StateSnapshot memory snapshot = _createStateSnapshot();
        RunespearProtocol.RunespearMessageEnvelope memory envelope =
            RunespearProtocol.RunespearMessageEnvelope({ payload: abi.encode(bridged), stateSnapshot: snapshot });

        _sendMessage(destinationChainId, RunespearProtocol.SYNC_BRIDGED, abi.encode(envelope));

        emit AssetsSent(latestOutboundNonce, token, amount, address(agent), destinationChainId);
        return latestOutboundNonce;
    }

    /**
     * @notice Bridge callback indicating assets have arrived on this chain.
     *         Callback is currently NOT supported by Rhino.fi; this callback is for future usage.
     *         Bridged assets coming BEFORE CCIP message would be automatically processed on the message arrival;
     *         those coming AFTER CCIP message must be "flushed" by `processPendingBridgeAssets`.
     * @dev Only whitelisted bridge contracts may call this function. A well-integrated bridge
     *      should (a) transfer tokens to the adapter and (b) invoke this callback within the same
     *      transaction so custody immediately transitions to the agent/vault path.
     *
     *      Flow on success:
     *      - Adapter holds the tokens temporarily.
     *      - `_processBridgeReceived` grants a one-shot approval to the agent.
     *      - The agent pulls funds, hands them to the vault, and nudges the messaging layer.
     *
     * @param operationNonce Source-chain nonce that identifies the bridge operation.
     * @param token Local token address received.
     * @param amount Amount forwarded by the bridge (checked against balance).
     * @param sourceChainId Chain ID that originated the transfer.
     * @param sentAt Timestamp from the source chain for ordering.
     */
    function onBridgeReceived(
        uint256 operationNonce,
        address token,
        uint256 amount,
        uint256 sourceChainId,
        uint256 sentAt
    )
        external
        override
    {
        // Callback is not implemented because the currently used bridge does not support this feature.
        revert NotImplemented();
        /*
        if (!authorizedBridges[msg.sender]) revert UnauthorizedBridge();

        _processBridgeReceived(operationNonce, token, amount, sourceChainId, sentAt);
        */
    }

    /**
     * @notice Attempt to clear a `SYNC_BRIDGED` notification if funds are already available.
     * @dev Idempotent: if the nonce has been recorded previously, the call is treated as a no-op.
     *      Otherwise the notification is mapped to the local token, balances are checked after
     *      subtracting other reservations, and `_processBridgeReceived` is invoked once sufficient
     *      liquidity is present.
     *
     * @param notification Bridging metadata sent by the peer adapter.
     * @param sourceChainId Chain ID that sent the notification.
     * @return processed True when the notification is fully processed; false if we must wait longer.
     */
    function _tryProcessBridgeNotification(
        RunespearProtocol.Bridged memory notification,
        uint256 sourceChainId
    )
        internal
        returns (bool processed)
    {
        // Check if already processed via accountant
        if (_accountant.isInboundRecorded(notification.nonce)) {
            return true; // Already processed
        }

        // Resolve AssetType to local chain token address
        address token = _resolveAssetTypeToToken(notification.assetType);

        // Check if assets are available
        uint256 totalBalance = IERC20(token).balanceOf(address(this));
        if (totalBalance < notification.amount) {
            return false; // Not enough assets yet
        }

        // Assets available - process
        // Pass sentAt from notification for causality tracking
        _processBridgeReceived(notification.nonce, token, notification.amount, sourceChainId, notification.timestamp);
        return true;
    }

    /// @dev Inbound processing for bridge receipts
    function _processBridgeReceived(
        uint256 operationNonce,
        address token,
        uint256 expectedAmount,
        uint256 sourceChainId,
        uint256 sentAt
    )
        internal
    {
        if (token == address(0)) revert InvalidToken();
        if (token != bridgeToken) revert InvalidToken();
        if (expectedAmount == 0) revert ZeroAmount();

        // Check if already processed by consulting accountant
        if (_accountant.isInboundRecorded(operationNonce)) {
            // Already recorded in inbound tracker, skip duplicate processing
            return;
        }

        // Check if assets are available
        uint256 totalBalance = IERC20(token).balanceOf(address(this));
        if (totalBalance < expectedAmount) revert InsufficientBridgedAmount();

        _accountant.recordInbound(operationNonce, expectedAmount, sentAt);

        // Vault receives assets (we're the destination)
        if (vault == address(0)) revert InvalidVault();

        IERC20(token).forceApprove(address(agent), expectedAmount);
        agent.sendBridgedAssets(vault, operationNonce, token, expectedAmount, sourceChainId);

        emit AssetsReceived(operationNonce, token, expectedAmount, vault, sourceChainId);
    }

    /// @notice Calculate the total amount still required to settle awaiting-asset notifications for a token
    function _getAwaitingAssetRequirement(address token) internal view returns (uint256 required) {
        if (token == address(0)) {
            return 0;
        }

        uint256[] memory awaitingAssetNonces = _accountant.getAwaitingAssetNonces();
        for (uint256 i = 0; i < awaitingAssetNonces.length; i++) {
            (bool exists, RunespearProtocol.Bridged memory notification) =
                _accountant.getAwaitingAssetNotification(awaitingAssetNonces[i]);
            if (!exists || notification.nonce == 0) continue;

            address notificationToken = assetTypeToToken[notification.assetType];
            if (notificationToken != address(0) && notificationToken == token) {
                required += notification.amount;
            }
        }
    }

    // ============================================
    // Async Bridging Edge Case Handlers
    // ============================================

    /// @dev Processes INBOUND pending notifications (not outbound confirmations)
    ///      Called by keeper after bridge transfers complete out-of-order (assets arriving after message)
    function processPendingBridgeAssets() external onlyOperators {
        uint256 processedCount = 0;
        uint256[] memory awaitingAssetNonces = _accountant.getAwaitingAssetNonces();

        // Iterate in reverse so we can remove entries without shifting the remaining indexes.
        for (uint256 i = awaitingAssetNonces.length; i > 0; i--) {
            uint256 nonce = awaitingAssetNonces[i - 1];

            (bool exists, RunespearProtocol.Bridged memory notification) =
                _accountant.getAwaitingAssetNotification(nonce);

            if (!exists || notification.nonce == 0) {
                _accountant.removeAwaitingAssetNotification(nonce);
                continue;
            }

            bool processed = _tryProcessBridgeNotification(notification, notification.sourceChainId);

            if (processed) {
                _accountant.removeAwaitingAssetNotification(nonce);
                processedCount++;
                address token = _resolveAssetTypeToToken(notification.assetType);
                emit BridgeReceiptForced(notification.nonce, token, notification.amount, notification.sourceChainId);
            }
        }

        uint256 remainingCount = _accountant.getAwaitingAssetCount();
        emit AwaitingAssetNotificationsProcessed(processedCount, remainingCount);
    }

    function getOutboundAwaitingPeerReceiptNonces() external view returns (uint256[] memory) {
        return _accountant.getOutboundAwaitingPeerReceiptNonces();
    }

    function getAwaitingAssetNonces() external view returns (uint256[] memory) {
        return _accountant.getAwaitingAssetNonces();
    }

    // ============================================
    // State Snapshot Management & Overlap Calculation
    // ============================================

    function _createStateSnapshot() internal view returns (SuperEarnV2Protocol.StateSnapshot memory) {
        SuperEarnV2Protocol.VaultState memory vaultState;

        if (vault != address(0) && _localVaultRoleConfigured) {
            vaultState = VaultStateHelper.getVaultState(vault, _localVaultRole);
        }

        return SuperEarnV2Protocol.StateSnapshot({
            vaultState: vaultState,
            bridgeState: _accountant.getCurrentBridgeState()
        });
    }

    // ============================================
    // Vault Message Sending
    // ============================================

    function sendMessage(
        uint256 destinationChainId,
        bytes4 predicate,
        bytes memory args
    )
        public
        override
        returns (bytes32 messageId)
    {
        //SYNC_BRIDGED is only allowed to be sent by sendAssets function.
        if (predicate == RunespearProtocol.SYNC_BRIDGED) {
            revert InvalidPredicate();
        }

        if (
            !(
                msg.sender == vault || msg.sender == address(agent) || isGovernance(msg.sender)
                    || ((isManagement(msg.sender) || isKeeper(msg.sender)) && predicate == RunespearProtocol.SYNC_NOOP)
            )
        ) {
            revert UnauthorizedCaller();
        }

        if (block.timestamp == lastMessageSentAt) {
            revert DuplicateMessageSent();
        }
        lastMessageSentAt = block.timestamp;

        SuperEarnV2Protocol.StateSnapshot memory snapshot = _createStateSnapshot();
        RunespearProtocol.RunespearMessageEnvelope memory envelope =
            RunespearProtocol.RunespearMessageEnvelope({ payload: args, stateSnapshot: snapshot });

        return _sendMessage(destinationChainId, predicate, abi.encode(envelope));
    }

    function sendSyncNoop() external override {
        sendMessage(getPeerChainId(), RunespearProtocol.SYNC_NOOP, "");
    }

    // ============================================
    // Bridge Notification Handling
    // ============================================

    /**
     * @notice Handle an inbound `SYNC_BRIDGED` notification from the peer adapter.
     * @dev Clears the notification immediately when liquidity is present; otherwise queues it
     *      so `processPendingBridgeAssets` can retry after the bridge finishes delivering funds.
     *      Notifications often arrive before tokens, so keepers must tolerate and service the queue.
     *
     * @param bridged Notification payload emitted by the peer.
     * @param sourceChainId Chain that originated the notification.
     */
    function _handleBridged(RunespearProtocol.Bridged memory bridged, uint256 sourceChainId) internal {
        bool processed = _tryProcessBridgeNotification(bridged, sourceChainId);

        if (processed) {
            // Clear from pending if it was there (delegate to accountant)
            (bool exists,) = _accountant.getAwaitingAssetNotification(bridged.nonce);
            if (exists) {
                _accountant.removeAwaitingAssetNotification(bridged.nonce);
            }
        } else {
            // Assets not available yet - store as INBOUND pending (delegate to accountant)
            _accountant.addAwaitingAssetNotification(bridged);
            // Resolve AssetType to token for event emission
            address token = _resolveAssetTypeToToken(bridged.assetType);
            emit AwaitingAssetNotificationAdded(bridged.nonce, token, bridged.amount, sourceChainId);
        }
    }

    // ============================================
    // CCIP Message Handling
    // ============================================

    function _handle(uint256 sourceChainId, bytes4 predicate, bytes memory args, bytes32 messageId) internal override {
        RunespearProtocol.RunespearMessageEnvelope memory envelope =
            abi.decode(args, (RunespearProtocol.RunespearMessageEnvelope));

        // If the timestamp of the peer's snapshot is older than the timestamp of the peer's bridge state,
        // we do not update the peer snapshot and reconcile the bridge state.
        if (envelope.stateSnapshot.vaultState.timestamp > _accountant.getPeerTimestamp()) {
            _accountant.updatePeerSnapshot(envelope.stateSnapshot);
            _accountant.reconcileBridgeState(sourceChainId, envelope.stateSnapshot.bridgeState);
        }

        if (predicate == RunespearProtocol.SYNC_NOOP) {
            return;
        }
        if (predicate == RunespearProtocol.SYNC_BRIDGED) {
            _handleBridged(abi.decode(envelope.payload, (RunespearProtocol.Bridged)), sourceChainId);
            return;
        }

        // For all other messages, forward to agent for business logic routing
        agent.delegate(sourceChainId, predicate, args, messageId, envelope);
    }

    receive() external payable { }

    // ============================================
    // Defensive Message Retry Functions
    // ============================================

    /**
     * @notice Retry a specific failed message
     * @param messageId CCIP message ID to retry
     * @dev Available for both governance and managers (keepers)
     */
    function retryFailedMessage(bytes32 messageId) external onlyOperators nonReentrant {
        _retryFailedMessage(messageId);
    }

    /**
     * @notice Remove a failed message from storage (manual cleanup)
     * @param messageId CCIP message ID to remove
     * @dev Managers-only for safety (permanent removal)
     */
    function removeFailedMessage(bytes32 messageId) external onlyManagers {
        _removeFailedMessage(messageId);
    }

    // =============== Emergency ================
    /**
     * @notice Force processing of an inbound bridge nonce when automation fails.
     * @dev Normal operations should resolve through `onBridgeReceived` (bridge callback) or through
     *      `processPendingBridgeAssets` once a `SYNC_BRIDGED` notification lands. Invoke this function
     *      only when both automated paths stall even though the adapter already holds the funds.
     *
     *      Callers are expected to confirm off-chain that the balance exists, the token mapping is
     *      correct, and the amount matches post-fee expectations. On success, `_processBridgeReceived`
     *      runs exactly as it would for an automated arrival and a `BridgeReceiptForced` event is emitted
     *      for incident tracking.
     *
     * @param operationNonce Source-chain nonce being settled manually.
     * @param token Destination-chain token address for this nonce.
     * @param expectedAmount Amount that arrived on this chain (validated against adapter balance).
     * @param sourceChainId Chain ID that originated the transfer.
     */
    function forceProcessBridgeReceipt(
        uint256 operationNonce,
        address token,
        uint256 expectedAmount,
        uint256 sourceChainId
    )
        external
        onlyGovernance
    {
        if (token != bridgeToken) revert InvalidToken();

        // Emit explicit incident event before attempting settlement.
        emit BridgeReceiptForced(operationNonce, token, expectedAmount, sourceChainId);

        // Derive the original sentAt if we previously queued a notification; otherwise fall back
        // to the current timestamp for conservative ordering.
        uint256 sentAt = block.timestamp;
        (bool exists, RunespearProtocol.Bridged memory notification) =
            _accountant.getAwaitingAssetNotification(operationNonce);
        if (exists && notification.nonce != 0) {
            sentAt = notification.timestamp;
        }

        // Always trust the caller-supplied token/amount: the pending notification may reference the
        // source-chain token, which is not deployable locally.
        _processBridgeReceived(operationNonce, token, expectedAmount, sourceChainId, sentAt);

        // Clean up any stale notification record now that the nonce has been finalized.
        if (exists) {
            _accountant.removeAwaitingAssetNotification(operationNonce);
        }
    }

    function sweepableBalance(address token) public view override returns (uint256) {
        if (token == address(0)) revert InvalidToken();

        uint256 totalBalance = IERC20(token).balanceOf(address(this));
        uint256 pendingRequirement = _getAwaitingAssetRequirement(token);

        if (totalBalance <= pendingRequirement) {
            return 0;
        }
        return totalBalance - pendingRequirement;
    }

    function sweepToken(address token, address to, uint256 amount) external override onlyGovernance {
        if (token == address(0) || to == address(0)) revert InvalidAddress();

        uint256 sweepable = sweepableBalance(token);
        if (amount == type(uint256).max) {
            amount = sweepable;
        }

        if (amount == 0) revert ZeroAmount();
        if (amount > sweepable) revert InsufficientSweepableBalance(amount, sweepable);

        IERC20(token).safeTransfer(to, amount);
        emit TokenSwept(token, to, amount);
    }

    function sweepEth(address to, uint256 amount) external override onlyGovernance {
        if (to == address(0)) revert InvalidAddress();

        uint256 balance = address(this).balance;
        if (amount == type(uint256).max) {
            amount = balance;
        }

        if (amount == 0) revert ZeroAmount();
        if (amount > balance) revert InsufficientSweepableBalance(amount, balance);

        // Use call for ETH transfer to prevent issues with contracts that have receive/fallback logic
        // Still safe because:
        // 1. Only governance can call this function (onlyGovernance modifier)
        // 2. Amount is capped at contract balance
        // 3. No state changes after the transfer (CEI pattern followed)
        (bool success,) = to.call{ value: amount }("");
        if (!success) revert TransferFailed();

        emit EthSwept(to, amount);
    }

    // =========== Interface ============

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControlUpgradeable, CCIPReceiverUpgradeable)
        returns (bool)
    {
        return interfaceId == type(ICrosschainAdapter).interfaceId
            || interfaceId == type(IAccessControlUpgradeable).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 10 slots (CrosschainAdapter itself)
     *   - vault: 1 slot (address)
     *   - originChainId: 1 slot (uint256)
     *   - remoteChainId: 1 slot (uint256)
     *   - peerVault: 1 slot (address)
     *   - agent: 1 slot (address)
     *   - bridgeDepositAddress: 1 slot (address)
     *   - authorizedBridges (mapping pointer): 1 slot
     *   - peerAdapter: 1 slot (address)
     *   - _localVaultRole / _localVaultRoleConfigured: 1 slot (packed enum + bool)
     *   - assetTypeToToken (mapping pointer): 1 slot
     *
     * Note: Storage consumed by inherited contracts (RunespearReceiver/Sender, AccessControl, ReentrancyGuard)
     * is accounted for in their own implementations.
     *
     * Gap = 50 - 10 = 40
     */
    uint256[40] private __gap;
}
