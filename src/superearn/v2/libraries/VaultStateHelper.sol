// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SuperEarnV2Protocol } from "../messaging/SuperEarnV2Protocol.sol";
import { ICrosschainVault } from "../interfaces/ICrosschainVault.sol";
import { IRemoteVault } from "../interfaces/IRemoteVault.sol";

/**
 * @title VaultStateHelper
 * @notice External library for querying vault state information
 * @dev Extracted from CrosschainAdapter to reduce contract size
 *
 * ## Purpose
 * Provides standardized vault state queries for both Origin and Remote vaults:
 * - Total assets (from ERC4626)
 * - Idle assets (from balance or vault-specific query)
 * - Unfulfilled withdrawal amounts (Remote only)
 * - Asset type (USDT for Origin, USDC for Remote)
 */
library VaultStateHelper {
    // ============================================
    // Errors
    // ============================================

    error InvalidVault();
    error UnknownVaultRole();

    // ============================================
    // Public Functions
    // ============================================

    /**
     * @notice Get vault state for a specific vault role.
     * @param vault Address of vault to query
     * @param role Statically configured role for the vault
     * @return state The vault state snapshot
     */
    function getVaultState(address vault, ICrosschainVault.VaultRole role)
        external
        view
        returns (SuperEarnV2Protocol.VaultState memory state)
    {
        if (vault == address(0)) revert InvalidVault();

        if (role == ICrosschainVault.VaultRole.Origin) {
            return getOriginState(vault);
        } else if (role == ICrosschainVault.VaultRole.Remote) {
            return getRemoteState(vault);
        } else {
            revert UnknownVaultRole();
        }
    }

    /**
     * @notice Get state for a Remote vault (Ethereum Yearn vault)
     * @dev Queries RemoteVault-specific information
     * @param vault Address of remote vault
     * @return state The vault state snapshot
     */
    function getRemoteState(address vault) public view returns (SuperEarnV2Protocol.VaultState memory state) {
        if (vault == address(0)) revert InvalidVault();

        IRemoteVault remote = IRemoteVault(vault);

        uint256 totalAssets = IERC4626(vault).totalAssets();
        uint256 idleAssets = remote.idleAssets();
        uint256 unfulfilledAmount = remote.getUnfulfilledWithdrawalInfo();

        return SuperEarnV2Protocol.VaultState({
            totalAssets: totalAssets,
            idleAssets: idleAssets,
            timestamp: block.timestamp,
            unfulfilledWithdrawalAmount: unfulfilledAmount,
            assetType: SuperEarnV2Protocol.AssetType.USDC
        });
    }

    /**
     * @notice Get state for an Origin vault (Kaia user-facing vault)
     * @dev Queries OriginVault-specific information
     * @param vault Address of origin vault
     * @return state The vault state snapshot
     */
    function getOriginState(address vault) public view returns (SuperEarnV2Protocol.VaultState memory state) {
        if (vault == address(0)) revert InvalidVault();

        uint256 totalAssets = IERC4626(vault).totalAssets();
        address asset = IERC4626(vault).asset();
        uint256 idleAssets = IERC20(asset).balanceOf(vault);

        return SuperEarnV2Protocol.VaultState({
            totalAssets: totalAssets,
            idleAssets: idleAssets,
            timestamp: block.timestamp,
            unfulfilledWithdrawalAmount: 0,
            assetType: SuperEarnV2Protocol.AssetType.USDT
        });
    }
}
