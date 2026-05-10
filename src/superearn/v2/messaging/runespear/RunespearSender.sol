// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { RunespearLib } from "@runespear/RunespearLib.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RunespearSender
 * @notice Base contract for sending Runespear messages via CCIP
 * @dev Handles message encoding, routing, and fee management
 */
abstract contract RunespearSender is Initializable {
    using SafeERC20 for IERC20;
    using RunespearLib for bytes4;

    // === Custom Errors ===
    error InvalidRouterAddress();
    error InvalidChainId();
    error InvalidPeer();
    error InsufficientFeeToken();
    error UnauthorizedCaller();
    error ChainNotConfigured();

    // === Events ===
    event RunespearMessageSent(
        uint256 indexed destinationChainId, address indexed peer, bytes4 predicate, bytes32 messageId, uint256 ccipFee
    );

    event ChainConfigured(uint256 indexed chainId, uint64 chainSelector, address peer);

    event PeerUpdated(uint256 indexed chainId, address oldPeer, address newPeer);

    // === State Variables ===

    /**
     * @notice Chain configuration
     */
    struct ChainConfig {
        uint64 chainSelector; // CCIP chain selector
        address peer; // Whitelisted peer on destination chain
        bool isActive; // Whether this chain is active
        uint256 gasLimit; // Gas limit for CCIP execution
    }

    address public ccipRouter;
    address public feeToken; // LINK or native token for CCIP fees

    mapping(uint256 => ChainConfig) public chainConfigs;
    mapping(bytes32 => bool) public sentMessages;

    uint256 public defaultGasLimit;
    uint256 public nonce;

    // === Constructor ===

    constructor() {
        _disableInitializers();
    }

    function __RunespearSender_init(address _router, address _feeToken) internal onlyInitializing {
        defaultGasLimit = 500_000;
        __RunespearSender_init_unchained(_router, _feeToken);
    }

    function __RunespearSender_init_unchained(address _router, address _feeToken) internal onlyInitializing {
        if (_router == address(0)) revert InvalidRouterAddress();
        ccipRouter = _router;
        feeToken = _feeToken;
    }

    // === Configuration Functions ===

    /**
     * @notice Configure a destination chain
     * @param chainId Destination chain ID
     * @param chainSelector CCIP chain selector
     * @param peer Whitelisted peer address
     * @param gasLimit Gas limit for execution
     */
    function _configureChain(uint256 chainId, uint64 chainSelector, address peer, uint256 gasLimit) internal {
        if (chainId == 0) revert InvalidChainId();
        if (peer == address(0)) revert InvalidPeer();

        chainConfigs[chainId] = ChainConfig({
            chainSelector: chainSelector,
            peer: peer,
            isActive: true,
            gasLimit: gasLimit > 0 ? gasLimit : defaultGasLimit
        });

        emit ChainConfigured(chainId, chainSelector, peer);
    }

    /**
     * @notice Update peer for a chain
     * @param chainId Destination chain ID
     * @param newPeer New peer address
     */
    function _updatePeer(uint256 chainId, address newPeer) internal {
        if (newPeer == address(0)) revert InvalidPeer();

        ChainConfig storage config = chainConfigs[chainId];
        if (!config.isActive) revert ChainNotConfigured();

        address oldPeer = config.peer;
        config.peer = newPeer;

        emit PeerUpdated(chainId, oldPeer, newPeer);
    }

    // === Message Sending Functions ===

    /**
     * @notice Send a Runespear message via CCIP
     * @param destinationChainId Target chain ID
     * @param predicate The intent or function selector
     * @param args Encoded arguments
     * @return messageId CCIP message ID
     */
    function _sendRunespearMessage(
        uint256 destinationChainId,
        bytes4 predicate,
        bytes memory args
    )
        internal
        returns (bytes32 messageId)
    {
        ChainConfig memory config = chainConfigs[destinationChainId];
        if (!config.isActive) revert ChainNotConfigured();

        // Encode Runespear message
        bytes memory runespearMessage = RunespearLib.encodeMessage(predicate, args);

        // Send via CCIP
        messageId = _sendCCIPMessage(config.chainSelector, config.peer, runespearMessage, config.gasLimit);

        sentMessages[messageId] = true;

        emit RunespearMessageSent(destinationChainId, config.peer, predicate, messageId, _getLastCCIPFee());
    }

    /**
     * @notice Send a Runespear message (alias for _sendRunespearMessage)
     * @param destinationChainId Target chain ID
     * @param predicate The intent or function selector
     * @param args Encoded arguments
     * @return messageId CCIP message ID
     */
    function _sendMessage(
        uint256 destinationChainId,
        bytes4 predicate,
        bytes memory args
    )
        internal
        returns (bytes32 messageId)
    {
        return _sendRunespearMessage(destinationChainId, predicate, args);
    }

    // === CCIP Integration ===

    uint256 private lastCCIPFee;

    /**
     * @notice Internal function to send CCIP message
     */
    function _sendCCIPMessage(
        uint64 chainSelector,
        address receiver,
        bytes memory data,
        uint256 gasLimit
    )
        private
        returns (bytes32)
    {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: gasLimit }))
        });

        uint256 fee = IRouterClient(ccipRouter).getFee(chainSelector, message);
        lastCCIPFee = fee;

        if (feeToken != address(0)) {
            // Pay with ERC20 token
            if (IERC20(feeToken).balanceOf(address(this)) < fee) {
                revert InsufficientFeeToken();
            }
            IERC20(feeToken).forceApprove(ccipRouter, fee);
            return IRouterClient(ccipRouter).ccipSend(chainSelector, message);
        } else {
            // Pay with native token
            if (address(this).balance < fee) {
                revert InsufficientFeeToken();
            }
            return IRouterClient(ccipRouter).ccipSend{ value: fee }(chainSelector, message);
        }
    }

    /**
     * @notice Get the last CCIP fee paid
     */
    function _getLastCCIPFee() private view returns (uint256) {
        return lastCCIPFee;
    }

    // === Fee Estimation ===

    /**
     * @notice Estimate CCIP fee for a message
     * @param destinationChainId Target chain ID
     * @param dataSize Approximate data size in bytes
     * @return fee Estimated CCIP fee
     */
    function estimateFee(uint256 destinationChainId, uint256 dataSize) public view returns (uint256 fee) {
        ChainConfig memory config = chainConfigs[destinationChainId];
        if (!config.isActive) revert ChainNotConfigured();

        // Create a dummy message for fee estimation
        bytes memory dummyData = new bytes(dataSize);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(config.peer),
            data: dummyData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({ gasLimit: config.gasLimit }))
        });

        return IRouterClient(ccipRouter).getFee(config.chainSelector, message);
    }

    // === View Functions ===

    /**
     * @notice Check if a chain is configured and active
     * @param chainId Chain ID to check
     * @return isActive True if the chain is configured and active
     */
    function isChainActive(uint256 chainId) public view returns (bool) {
        return chainConfigs[chainId].isActive;
    }

    /**
     * @notice Get peer address for a chain
     * @param chainId Chain ID
     * @return Peer address
     */
    function getPeer(uint256 chainId) public view returns (address) {
        return chainConfigs[chainId].peer;
    }

    /**
     * @notice Get chain selector for a chain ID
     * @param chainId Chain ID
     * @return CCIP chain selector
     */
    function getChainSelector(uint256 chainId) public view returns (uint64) {
        return chainConfigs[chainId].chainSelector;
    }

    /**
     * Storage usage: 6 slots
     *   - ccipRouter
     *   - feeToken
     *   - chainConfigs mapping pointer
     *   - sentMessages mapping pointer
     *   - defaultGasLimit
     *   - nonce
     *
     * Gap = 50 - 6 = 44
     */
    uint256[44] private __gap;
}
