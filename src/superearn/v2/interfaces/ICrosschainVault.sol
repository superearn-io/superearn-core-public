// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title ICrosschainVault
 * @notice Interface that vaults must implement to receive agent notifications
 * @dev Called by RunespearAgent to notify vault of crosschain events
 *      Note: Agent abstracts away all adapter/bridge details
 */
interface ICrosschainVault {
    /**
     * @notice Distinguishes whether the vault is the origin or remote leg.
     */
    enum VaultRole {
        Origin,
        Remote
    }

    /**
     * @notice Returns the statically defined role of the vault.
     * @dev Must return a constant so the adapter/agent can rely on it without ERC-165 introspection.
     */
    function vaultRole() external pure returns (VaultRole);
}
