// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRunespearAgent } from "../../interfaces/IRunespearAgent.sol";
import { ICrosschainAdapter } from "../../interfaces/ICrosschainAdapter.sol";
import { IBridgeAccountant } from "../../interfaces/IBridgeAccountant.sol";
import { ICrosschainVault } from "../../interfaces/ICrosschainVault.sol";
import { IRemoteVault } from "../../interfaces/IRemoteVault.sol";
import { SuperEarnV2Protocol } from "../../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../../messaging/runespear/RunespearProtocol.sol";
import { SuperEarnAccessControl } from "../../base/SuperEarnAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title SuperEarnMessageAgent
 * @notice Routes SuperEarn V2 crosschain messages to appropriate vault handlers
 * @dev Fully isolated message routing logic - swappable at runtime
 *
 * ## Architectural Role
 *
 * This agent is the **business logic layer** for crosschain message routing:
 * - CrosschainAdapter = Infrastructure (CCIP, bridge operations)
 * - SuperEarnMessageAgent = Business logic (message routing)
 * - Vaults = State machines (vault operations)
 *
 * ## Message Flow
 *
 * 1. CCIP delivers message to CrosschainAdapter
 * 2. Adapter validates and decodes envelope
 * 3. Adapter delegates to this agent via `handle()`
 * 4. Agent routes based on predicate to appropriate vault
 * 5. Vault executes business logic
 *
 * ## Upgradeability
 *
 * Since this agent is external to the adapter:
 * - Can be replaced without touching adapter or vaults
 * - Enables A/B testing of routing strategies
 * - Allows gradual rollout of new message types
 *
 * ## Security Model
 *
 * - Only the configured CrosschainAdapter can call this agent
 * - Agent has no direct token custody (vaults do)
 * - Agent only routes; vaults enforce access control
 * - Uses SuperEarnAccessControl for consistent governance
 *
 * ## Access Control
 *
 * - GOVERNANCE_ROLE: Can set adapter, rescue stuck assets
 * - No other roles needed (agent is infrastructure only)
 */
contract SuperEarnMessageAgent is Initializable, IRunespearAgent, SuperEarnAccessControl {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // Errors
    // ============================================

    error OnlyAdapter();
    error InvalidAdapter();
    error InvalidAddress();
    error OnlyVault();
    error OnlyGovernanceOrVault();
    error UnknownPredicate();
    error UnknownAssetType();

    // ============================================
    // State Variables
    // ============================================

    /// @notice CrosschainAdapter that can invoke this agent
    ICrosschainAdapter public adapter;

    // ============================================
    // Events
    // ============================================

    event AdapterSet(address indexed adapter);
    event MessageRouted(uint256 indexed sourceChainId, bytes4 indexed predicate, address indexed targetVault);
    event UnknownPredicateReceived(uint256 indexed sourceChainId, bytes4 indexed predicate, bytes32 indexed messageId);

    // ============================================
    // Initializer
    // ============================================

    /**
     * @notice Initialize the message agent
     * @param _adapter Address of the CrosschainAdapter
     */
    /**
     * @notice Initialize the SuperEarnMessageAgent
     * @param _adapter Address of the CrosschainAdapter
     * @param _owner Owner address that will receive GOVERNANCE_ROLE
     */
    function initialize(address _adapter, address _owner) public initializer {
        __SuperEarnAccessControl_init();
        if (_adapter == address(0)) revert InvalidAdapter();
        if (_owner == address(0)) revert InvalidAddress();

        adapter = ICrosschainAdapter(_adapter);
        emit AdapterSet(_adapter);

        // Grant GOVERNANCE_ROLE to owner
        _grantRole(GOVERNANCE_ROLE, _owner);
    }

    // ============================================
    // Configuration
    // ============================================

    /**
     * @notice Update the adapter address
     * @param _adapter New adapter address
     * @dev Only governance can change adapter (critical routing control)
     */
    function setAdapter(address _adapter) external onlyGovernance {
        if (_adapter == address(0)) revert InvalidAdapter();
        adapter = ICrosschainAdapter(_adapter);
        emit AdapterSet(_adapter);
    }

    // ============================================
    // Message Handling
    // ============================================

    /**
     * @notice Handle incoming Runespear message
     * @dev Routes message to appropriate vault based on predicate
     * @param sourceChainId Source chain ID
     * @param predicate Message predicate
     * @param envelope Decoded message envelope
     */
    function delegate(
        uint256 sourceChainId,
        bytes4 predicate,
        bytes memory, /* args */
        bytes32 messageId,
        RunespearProtocol.RunespearMessageEnvelope calldata envelope
    )
        external
        override
    {
        // Only adapter can invoke
        if (msg.sender != address(adapter)) revert OnlyAdapter();

        // Route based on predicate
        // Note: Bridge state reconciliation is handled by adapter before calling this agent
        if (predicate == SuperEarnV2Protocol.WITHDRAW) {
            _routeWithdraw(envelope.payload, sourceChainId);
        } else {
            // Emit event instead of reverting for safety and observability
            emit UnknownPredicateReceived(sourceChainId, predicate, messageId);
        }
    }

    // ============================================
    // Internal Routing Functions
    // ============================================

    /**
     * @notice Handle WITHDRAW request
     * @dev Routes to vault (must be remote)
     */
    function _routeWithdraw(bytes calldata payload, uint256 sourceChainId) internal {
        uint256 usdtAmount = abi.decode(payload, (uint256));
        address vault = adapter.vault();

        IRemoteVault(vault).handleWithdrawRequest(usdtAmount);
        // adapter.sendAcknowledgement(SuperEarnV2Protocol.WITHDRAW);
        // NOTE: may be unnecessary because either the requested
        // amount is bridged back or nothing happens for now (unfulfilled)

        emit MessageRouted(sourceChainId, SuperEarnV2Protocol.WITHDRAW, vault);
    }

    // ============================================
    // Outbound Operations (Vault → Agent → Adapter)
    // ============================================

    /**
     * @notice Send message to peer vault
     * @dev Called by vault; orchestrates message sending via adapter
     *
     * Flow: Vault → Agent → Adapter → CCIP
     * This removes crosschain awareness from vaults
     *
     * @param predicate Message type
     * @param payload Message payload
     */
    function sendMessage(bytes4 predicate, bytes memory payload) external override {
        // Determine destination chain based on caller
        if (msg.sender != adapter.vault()) {
            revert OnlyVault();
        }

        uint256 destinationChainId = _getPeerChainId(msg.sender);

        // Forward to adapter
        adapter.sendMessage(destinationChainId, predicate, payload);
    }

    /**
     * @notice Get assets in transit to peer
     * @dev Called by vault for totalAssets calculation
     * @return Amount of assets in transit
     */
    function getAssetsInTransit() external view override returns (uint256) {
        // Query accountant via adapter
        IBridgeAccountant accountant = IBridgeAccountant(adapter.accountant());
        return accountant.calculateTrueOutboundInTransit();
    }

    /**
     * @notice Get true peer assets (with overlap removed)
     * @dev Returns both the adjusted amount and the decimals of the reported asset
     *      so OriginVault can normalize units before conversion.
     * @return assets True peer assets
     * @return assetDecimals Decimals of peer asset token
     */
    function getTruePeerAssets() external view override returns (uint256 assets, uint8 assetDecimals) {
        IBridgeAccountant accountant = IBridgeAccountant(adapter.accountant());
        SuperEarnV2Protocol.AssetType assetType;
        (assets, assetType) = accountant.calculateTruePeerAssets();

        assetDecimals = _assetTypeDecimals(assetType);
        return (assets, assetDecimals);
    }

    function _assetTypeDecimals(SuperEarnV2Protocol.AssetType assetType) internal pure returns (uint8) {
        if (assetType == SuperEarnV2Protocol.AssetType.USDC) return 6;
        if (assetType == SuperEarnV2Protocol.AssetType.USDT) return 6;
        revert UnknownAssetType();
    }

    /**
     * @notice Prepare and send assets with full agent custody flow
     * @dev Vault transfers to agent → Agent approves adapter → Agent calls adapter
     *      Complete adapter isolation for vault
     *
     * @param asset Asset to bridge
     * @param amount Amount to bridge
     * @return nonce Bridge operation nonce
     */
    function prepareAndSendAssets(address asset, uint256 amount) external override returns (uint256 nonce) {
        // Only vault can call
        if (msg.sender != adapter.vault()) {
            revert OnlyVault();
        }

        // 1. Pull assets from vault to agent
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Agent approves adapter to spend
        IERC20(asset).forceApprove(address(adapter), amount);

        // 3. Agent calls adapter (adapter will pull from agent)
        uint256 destinationChainId = _getPeerChainId(msg.sender);
        nonce = adapter.sendAssets(asset, amount, destinationChainId);

        // Asset flow: Vault → Agent → Adapter → Bridge
    }

    // ============================================
    // Inbound Callbacks (Adapter → Agent → Vault)
    // ============================================

    /**
     * @notice Send bridged assets to vault
     */
    function sendBridgedAssets(
        address targetVault,
        uint256 nonce,
        address token,
        uint256 amount,
        uint256 sourceChainId
    )
        external
        override
    {
        // Only adapter can call
        if (msg.sender != address(adapter)) revert OnlyAdapter();

        IERC20(token).safeTransferFrom(msg.sender, targetVault, amount);
    }

    // ============================================
    // Internal Helper Functions
    // ============================================

    /**
     * @notice Determine peer chain ID based on caller
     * @dev Uses adapter's interface detection to determine vault type and route accordingly
     * @param caller Vault address calling the agent
     * @return Peer chain ID
     */
    function _getPeerChainId(address caller) internal view returns (uint256) {
        if (caller != adapter.vault()) {
            revert OnlyVault(); // Only configured vault can call
        }

        return adapter.getPeerChainId();
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 1 slot (adapter)
     * Gap = 50 - 1 = 49
     */
    uint256[49] private __gap;
}
