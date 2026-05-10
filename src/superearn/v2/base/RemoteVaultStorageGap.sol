// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title RemoteVaultStorageGap
 * @notice Placeholder contract that reserves storage slots for RemoteVault upgrade compatibility
 * @dev This contract exists solely to maintain storage layout compatibility when upgrading
 *      RemoteVault from v1.0.0-eth (which inherited ERC4626Upgradeable) to the current version.
 *
 *      CRITICAL: This contract inherits ContextUpgradeable to maintain C3 linearization
 *      compatibility with SuperEarnAccessControl (which also inherits Context via AccessControl).
 *      In v1.0.0-eth, ERC4626 and SuperEarnAccessControl shared the same Context through
 *      diamond inheritance. Without inheriting Context here, SuperEarnAccessControl's Context
 *      would create separate storage slots, causing a 50-slot shift.
 *
 *      Storage layout of removed inheritance chain (OpenZeppelin 4.9.4):
 *
 *      - ContextUpgradeable: 0 state variables + 50 gap = 50 slots
 *        - __gap[50]: slots 1-50 (inherited, shared with SuperEarnAccessControl)
 *
 *      - ERC20Upgradeable: 5 state variables + 45 gap = 50 slots
 *        - _balances (mapping): slot 51
 *        - _allowances (mapping): slot 52
 *        - _totalSupply (uint256): slot 53
 *        - _name (string): slot 54
 *        - _symbol (string): slot 55
 *        - __gap[45]: slots 56-100
 *
 *      - ERC4626Upgradeable: 1 packed slot + 49 gap = 50 slots
 *        - _asset (IERC20) + _underlyingDecimals (uint8): slot 101 (packed)
 *        - __gap[49]: slots 102-150
 *
 *      Total: 100 additional storage slots reserved (Context's 50 inherited separately)
 *
 * @custom:security This contract MUST remain unchanged after deployment.
 *                  Any modification will cause storage collision in upgraded proxies.
 */
abstract contract RemoteVaultStorageGap is ContextUpgradeable {
    /**
     * @dev Reserved storage slots for ERC20Upgradeable + ERC4626Upgradeable
     *      (ContextUpgradeable's 50 slots are handled by inheritance)
     *      These slots were previously occupied by:
     *      - ERC20: _balances, _allowances, _totalSupply, _name, _symbol, __gap[45]
     *      - ERC4626: _asset, _underlyingDecimals, __gap[49]
     */
    uint256[100] private __remoteVault_storage_gap;
}
