// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { RunespearLib } from "@runespear/RunespearLib.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { CCIPReceiverUpgradeable } from "../ccip/CCIPReceiverUpgradeable.sol";

/**
 * @title RunespearReceiver
 * @notice Base contract for receiving and processing Runespear messages via CCIP
 * @dev Handles message validation, decoding, and routing to handlers
 */
abstract contract RunespearReceiver is CCIPReceiverUpgradeable {
    using RunespearLib for bytes;

    // === Custom Errors ===
    error InvalidSourceChain();
    error UnauthorizedSender();
    error InvalidMessage();
    error MessageAlreadyProcessed();
    error MessageNotFailed();

    // === Events ===
    event RunespearMessageReceived(
        uint256 indexed sourceChainId, address indexed sender, bytes4 predicate, bytes32 messageId
    );

    event MessageFailed(bytes32 indexed messageId, uint256 indexed sourceChainId, address sender);

    event MessageRecovered(bytes32 indexed messageId);

    // === State Variables ===

    /**
     * @notice Failed message data for defensive error handling
     */
    struct FailedMessage {
        uint64 sourceChainSelector; // CCIP source chain selector
        bytes sender; // Encoded sender address
        bytes data; // Original payload
        bytes destTokenAmounts; // ABI-encoded token amounts array
        uint256 sourceChainId; // Source chain ID (from selector mapping)
        bytes errorReason; // Error reason from catch block
        uint256 timestamp; // When the failure occurred
    }

    // Failed messages storage
    mapping(bytes32 => FailedMessage) public failedMessages;
    bytes32[] public failedMessageIds;
    // Message ID => array index (1-based, 0 means not in array)
    mapping(bytes32 => uint256) private failedMessageIdIndex;

    /**
     * @notice Source chain configuration
     */
    struct SourceConfig {
        address whitelistedSender; // Authorized sender on source chain
        bool isActive; // Whether this source is active
    }

    // Chain ID => Source configuration
    mapping(uint256 => SourceConfig) public sourceConfigs;

    // Chain selector => Chain ID mapping
    mapping(uint64 => uint256) public selectorToChainId;

    // Message ID => Processed flag
    mapping(bytes32 => bool) public processedMessages;

    // === Constructor ===

    constructor() {
        _disableInitializers();
    }

    function __RunespearReceiver_init(address router) internal onlyInitializing {
        __CCIPReceiver_init(router);
        __RunespearReceiver_init_unchained();
    }

    function __RunespearReceiver_init_unchained() internal onlyInitializing { }

    // === Configuration Functions ===

    /**
     * @notice Configure a source chain
     * @param chainId Source chain ID
     * @param chainSelector CCIP chain selector
     * @param whitelistedSender Authorized sender address
     */
    function _configureSource(uint256 chainId, uint64 chainSelector, address whitelistedSender) internal {
        if (chainId == 0) revert InvalidSourceChain();
        if (whitelistedSender == address(0)) revert UnauthorizedSender();

        sourceConfigs[chainId] = SourceConfig({ whitelistedSender: whitelistedSender, isActive: true });

        selectorToChainId[chainSelector] = chainId;
    }

    /**
     * @notice Update whitelisted sender for a chain
     * @param chainId Source chain ID
     * @param newSender New whitelisted sender address
     */
    function _updateWhitelistedSender(uint256 chainId, address newSender) internal {
        if (newSender == address(0)) revert UnauthorizedSender();

        SourceConfig storage config = sourceConfigs[chainId];
        if (!config.isActive) revert InvalidSourceChain();

        config.whitelistedSender = newSender;
    }

    // === CCIP Receiver Implementation ===

    /**
     * @notice Internal handler for CCIP messages (DEFENSIVE)
     * @param message The CCIP message
     * @dev Implements defensive pattern: saves failed messages instead of reverting
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        // Prevent replay attacks
        if (processedMessages[message.messageId]) revert MessageAlreadyProcessed();

        // Get source chain ID
        uint256 sourceChainId = selectorToChainId[message.sourceChainSelector];
        if (sourceChainId == 0) revert InvalidSourceChain();

        // Validate sender
        address sender = abi.decode(message.sender, (address));
        SourceConfig memory config = sourceConfigs[sourceChainId];

        if (!config.isActive || sender != config.whitelistedSender) {
            revert UnauthorizedSender();
        }

        // DEFENSIVE PATTERN: Try to process message, save if it fails
        try this.processMessage(message, sourceChainId) { }
        catch (bytes memory reason) {
            // Failure - save for retry
            _saveFailedMessage(message, sourceChainId, reason);
            emit MessageFailed(message.messageId, sourceChainId, sender);
            // DO NOT revert - message is saved and can be retried
        }
    }

    /**
     * @notice External wrapper for message processing (enables try-catch)
     * @param message The CCIP message
     * @param sourceChainId Source chain ID
     * @dev Must be external to be callable via try-catch
     */
    function processMessage(Client.Any2EVMMessage memory message, uint256 sourceChainId) external {
        // Only callable by this contract (via try-catch)

        if (msg.sender != address(this)) revert UnauthorizedSender();

        // Decode Runespear message
        RunespearLib.Message memory runespearMessage = RunespearLib.decodeMessage(message.data);

        address sender = abi.decode(message.sender, (address));

        emit RunespearMessageReceived(sourceChainId, sender, runespearMessage.predicate, message.messageId);

        // Process the message
        _processRunespearMessage(sourceChainId, runespearMessage, message.messageId);

        // Success - mark as processed
        processedMessages[message.messageId] = true;
    }

    // === Message Processing ===

    /**
     * @notice Process a Runespear message
     * @param sourceChainId Source chain ID
     * @param message The Runespear message
     * @param messageId CCIP message ID
     */
    function _processRunespearMessage(
        uint256 sourceChainId,
        RunespearLib.Message memory message,
        bytes32 messageId
    )
        internal
        virtual
    {
        // Process message via internal handler
        _handle(sourceChainId, message.predicate, message.args, messageId);
    }

    /**
     * @notice Internal predicate handler
     * @dev Override this to implement custom predicate handling
     * @param sourceChainId Source chain ID
     * @param predicate The predicate to handle
     * @param args The encoded arguments
     * @param messageId The CCIP message ID
     */
    function _handle(uint256 sourceChainId, bytes4 predicate, bytes memory args, bytes32 messageId) internal virtual;

    // === Query Functions ===

    /**
     * @notice Check if a message has been processed
     * @param messageId The CCIP message ID
     * @return True if the message has been processed
     */
    function isMessageProcessed(bytes32 messageId) external view returns (bool) {
        return processedMessages[messageId];
    }

    // === View Functions ===

    /**
     * @notice Get whitelisted sender for a chain
     * @param chainId Source chain ID
     * @return Whitelisted sender address
     */
    function getWhitelistedSender(uint256 chainId) external view returns (address) {
        return sourceConfigs[chainId].whitelistedSender;
    }

    /**
     * @notice Check if a source chain is active
     * @param chainId Source chain ID
     * @return True if the source is active
     */
    function isSourceActive(uint256 chainId) external view returns (bool) {
        return sourceConfigs[chainId].isActive;
    }

    // === Defensive Message Retry Functions ===

    /**
     * @notice Save a failed message for later retry
     * @param message The CCIP message that failed
     * @param sourceChainId Source chain ID
     * @param errorReason Error bytes from catch block
     */
    function _saveFailedMessage(
        Client.Any2EVMMessage memory message,
        uint256 sourceChainId,
        bytes memory errorReason
    )
        internal
    {
        // Check if already exists
        FailedMessage storage failed = failedMessages[message.messageId];
        if (failed.timestamp == 0) {
            // New failure - add to list and store index (1-based)
            failedMessageIds.push(message.messageId);
            failedMessageIdIndex[message.messageId] = failedMessageIds.length;
        }

        // Store/update failed message
        failed.sourceChainSelector = message.sourceChainSelector;
        failed.sender = message.sender;
        failed.data = message.data;
        if (message.destTokenAmounts.length > 0) {
            failed.destTokenAmounts = abi.encode(message.destTokenAmounts);
        } else if (failed.destTokenAmounts.length > 0) {
            delete failed.destTokenAmounts;
        }
        failed.sourceChainId = sourceChainId;
        failed.errorReason = errorReason;
        failed.timestamp = block.timestamp;
    }

    /**
     * @notice Retry a specific failed message
     * @param messageId CCIP message ID to retry
     * @dev Internal function - to be exposed by child contracts with access control
     */
    function _retryFailedMessage(bytes32 messageId) internal {
        FailedMessage storage failed = failedMessages[messageId];
        if (failed.timestamp == 0) revert MessageNotFailed();

        Client.EVMTokenAmount[] memory destTokenAmounts;
        if (failed.destTokenAmounts.length > 0) {
            destTokenAmounts = abi.decode(failed.destTokenAmounts, (Client.EVMTokenAmount[]));
        } else {
            destTokenAmounts = new Client.EVMTokenAmount[](0);
        }

        Client.Any2EVMMessage memory retryMessage = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: failed.sourceChainSelector,
            sender: failed.sender,
            data: failed.data,
            destTokenAmounts: destTokenAmounts
        });

        // Try to process again
        try this.processMessage(retryMessage, failed.sourceChainId) {
            _removeFailedMessage(messageId);
            emit MessageRecovered(messageId);
        } catch (bytes memory reason) {
            // Still failing - update error reason and timestamp
            failed.errorReason = reason;
            failed.timestamp = block.timestamp;
            emit MessageFailed(messageId, failed.sourceChainId, abi.decode(failed.sender, (address)));
        }
    }

    /**
     * @notice Remove a failed message from storage (manual cleanup)
     * @param messageId CCIP message ID to remove
     * @dev Internal function - to be exposed by child contracts with access control
     * @dev Uses index mapping for O(1) removal instead of O(n) array traversal
     */
    function _removeFailedMessage(bytes32 messageId) internal {
        if (failedMessages[messageId].timestamp == 0) return;

        // Get index (1-based, 0 means not in array)
        uint256 index = failedMessageIdIndex[messageId];
        if (index == 0) return; // Already removed or never added

        // Convert to 0-based index
        uint256 arrayIndex = index - 1;

        // Swap with last element and pop
        uint256 lastIndex = failedMessageIds.length - 1;
        bytes32 lastMessageId = failedMessageIds[lastIndex];

        failedMessageIds[arrayIndex] = lastMessageId;
        failedMessageIds.pop();

        // Update index of the moved element
        if (lastIndex != arrayIndex) {
            failedMessageIdIndex[lastMessageId] = index; // Keep same 1-based index
        }

        // Clear index mapping
        delete failedMessageIdIndex[messageId];

        // Remove from mapping
        delete failedMessages[messageId];
    }

    // === View Functions for Failed Messages ===

    /**
     * @notice Get all failed message IDs
     * @return Array of failed message IDs (empty if none)
     */
    function getFailedMessageIds() external view virtual returns (bytes32[] memory) {
        return failedMessageIds;
    }

    /**
     * @notice Get failed message details
     * @param messageId CCIP message ID
     * @return sourceChainId Source chain ID
     * @return errorReason Error bytes from catch block
     * @return timestamp When the failure occurred
     */
    function getFailedMessageDetails(bytes32 messageId)
        external
        view
        virtual
        returns (uint256 sourceChainId, bytes memory errorReason, uint256 timestamp)
    {
        FailedMessage memory failed = failedMessages[messageId];
        return (failed.sourceChainId, failed.errorReason, failed.timestamp);
    }

    /**
     * Storage usage: 6 slots
     *   - failedMessages mapping
     *   - failedMessageIds array
     *   - failedMessageIdIndex mapping
     *   - sourceConfigs mapping
     *   - selectorToChainId mapping
     *   - processedMessages mapping
     *
     * Gap = 50 - 6 = 44
     */
    uint256[44] private __gap;
}
