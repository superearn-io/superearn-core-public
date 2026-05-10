// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { RunespearReceiver } from "./RunespearReceiver.sol";
import { RunespearSender } from "./RunespearSender.sol";
import { RunespearLib } from "@runespear/RunespearLib.sol";

/**
 * @title RunespearTransceiver
 * @notice Combined contract for bidirectional Runespear communication
 * @dev Inherits from both RunespearReceiver and RunespearSender for full crosschain messaging
 */
abstract contract RunespearTransceiver is Initializable, RunespearReceiver, RunespearSender {
    constructor() {
        _disableInitializers();
    }

    function __RunespearTransceiver_init(address router, address feeToken) internal onlyInitializing {
        __RunespearReceiver_init(router);
        __RunespearSender_init(router, feeToken);
    }

    /**
     * @notice Configure bidirectional communication with a chain
     * @param chainId Chain ID for both sending and receiving
     * @param chainSelector CCIP chain selector
     * @param peer Address of peer contract on the other chain
     * @param gasLimit Gas limit for outbound messages
     */
    function _configureBidirectionalChain(
        uint256 chainId,
        uint64 chainSelector,
        address peer,
        uint256 gasLimit
    )
        internal
    {
        // Configure for receiving (from RunespearReceiver)
        _configureSource(chainId, chainSelector, peer);

        // Configure for sending (from RunespearSender)
        _configureChain(chainId, chainSelector, peer, gasLimit);
    }

    /**
     * @notice Check if chain is configured for bidirectional communication
     * @param chainId Chain ID to check
     * @return True if chain is configured for both sending and receiving
     */
    function isBidirectionalChainConfigured(uint256 chainId) public view returns (bool) {
        return sourceConfigs[chainId].isActive && chainConfigs[chainId].isActive;
    }

    /**
     * @notice Get the CCIP router address (from CCIPReceiver base)
     * @return Address of the CCIP router
     */
    function getRouter() public view virtual override returns (address) {
        return super.getRouter();
    }

    /**
     * Storage usage: no additional slots beyond parents.
     * Gap is kept full size for forward compatibility.
     */
    uint256[50] private __gap;
}
