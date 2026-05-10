// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { RunespearProtocol } from "../messaging/runespear/RunespearProtocol.sol";

/**
 * @title SuperEarnV2Protocol
 * @notice Core protocol definitions for SuperEarn V2 crosschain vault system
 * @dev Contains data structures and message predicates for Runespear communication
 *
 * Note: Bridge tracking structures have been moved to RunespearProtocol for reusability.
 * This library re-exports them for backward compatibility.
 */
library SuperEarnV2Protocol {
    // ============================================
    // Data Structures
    // ============================================

    /**
     * @notice Supported asset types for bridging and reporting
     * @dev Renamed from StablecoinType for better extensibility
     */
    enum AssetType {
        USDC,
        USDT
    }

    /**
     * @notice Vault state snapshot for crosschain communication
     * @param totalAssets Total assets (includes idle + deployed assets)
     * @param idleAssets Total idle assets (USDC + USDT in remote vault, or USDT in origin vault)
     * @param timestamp Timestamp when this state snapshot was taken
     * @param unfulfilledWithdrawalAmount Cumulative unfulfilled withdrawal amount awaiting bridge to origin
     * @param assetType Currency denomination of all amounts in this state (USDC or USDT)
     * @dev CRITICAL: All amounts must be in the currency specified by assetType
     *      - Remote vault reports in USDC (Yearn vault operates in USDC)
     *      - Origin vault reports in USDT (local vault operates in USDT)
     *      - Origin vault MUST convert remote USDC amounts to USDT using AssetPriceConverter
     */
    struct VaultState {
        uint256 totalAssets;
        uint256 idleAssets;
        uint256 timestamp;
        uint256 unfulfilledWithdrawalAmount;
        AssetType assetType;
    }

    /**
     * @notice Complete state snapshot combining vault and bridge state
     * @param vaultState Vault asset and operational data
     * @param bridgeState Bridge operations state (synchronized with vault state)
     * @dev Both states are captured at the same timestamp for accurate overlap calculations
     *      This struct is piggybacked on EVERY Runespear message via RunespearMessageEnvelope
     */
    struct StateSnapshot {
        VaultState vaultState;
        RunespearProtocol.BridgeState bridgeState;
    }

    // ============================================
    // Message Predicates
    // ============================================

    // === Version Management ===

    /// @notice Version salt for correct coordination
    bytes32 private constant VERSION_SALT = keccak256("SUPEREARN_PREDICATES_V1");

    // === Core Messages ===

    /// @notice Withdraw USDT from remote vault
    bytes4 public constant WITHDRAW = bytes4(keccak256(abi.encodePacked("withdraw(uint256)", VERSION_SALT)));
}
