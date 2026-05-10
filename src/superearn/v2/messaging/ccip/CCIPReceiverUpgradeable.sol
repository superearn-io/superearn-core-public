// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title CCIPReceiverUpgradeable
 * @notice Upgradeable version of Chainlink's CCIPReceiver with initializer-based router wiring.
 * @dev Mirrors CCIPReceiver behaviour but stores router address in upgradeable storage.
 */
abstract contract CCIPReceiverUpgradeable is Initializable, IAny2EVMMessageReceiver, IERC165 {
    address private _ccipRouter;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __CCIPReceiver_init(address router) internal onlyInitializing {
        __CCIPReceiver_init_unchained(router);
    }

    function __CCIPReceiver_init_unchained(address router) internal onlyInitializing {
        if (router == address(0)) revert InvalidRouter(address(0));
        _ccipRouter = router;
    }

    /// @notice IERC165 supports an interfaceId.
    /// @param interfaceId The interfaceId to check.
    /// @return true if the interfaceId is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(Client.Any2EVMMessage calldata message) external virtual override onlyRouter {
        _ccipReceive(message);
    }

    /// @notice Override this function in your implementation.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal virtual;

    /// @notice Return the current router
    function getRouter() public view virtual returns (address) {
        return _ccipRouter;
    }

    error InvalidRouter(address router);

    /// @dev only calls from the set router are accepted.
    modifier onlyRouter() {
        if (msg.sender != getRouter()) revert InvalidRouter(msg.sender);
        _;
    }

    /**
     * Storage usage: 1 slot (router address)
     * Gap = 50 - 1 = 49
     */
    uint256[49] private __gap;
}
