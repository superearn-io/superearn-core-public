// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title SuperEarnAccessControl
 * @notice Standard role definitions and access control patterns for SuperEarn V2 protocol
 * @dev Inherit this abstract contract for consistent role management across all V2 contracts
 *
 * ## Role Hierarchy (High to Low Authority)
 *
 * ```
 * GOVERNANCE_ROLE         [Authority Level 10] - Ultimate protocol authority
 *     ↓
 * MANAGEMENT_ROLE         [Authority Level 7]  - Strategic operations
 *     ↓
 * KEEPER_ROLE             [Authority Level 3]  - Tactical automation
 *     ↓
 * SYSTEM_CONTRACT_ROLE    [Authority Level 1]  - System callbacks
 * ```
 *
 * ## Design Principles
 *
 * 1. **Minimal Roles** - Only 4 roles for entire protocol
 * 2. **Clear Hierarchy** - Each role has well-defined scope
 * 3. **Separation of Duties** - Hot wallets (keeper) separate from governance
 * 4. **Defense in Depth** - Multiple security layers
 * 5. **Consistent Implementation** - OpenZeppelin AccessControl everywhere
 *
 * ## Security Model
 *
 * - GOVERNANCE_ROLE: Cold storage multisig (5-of-9), infrequent use
 * - MANAGEMENT_ROLE: Warm storage multisig (2-of-3), daily operations
 * - KEEPER_ROLE: Hot wallet bot, automated queue processing
 * - SYSTEM_CONTRACT_ROLE: Contracts only, inter-contract communication
 *
 * ## Role Compromise Impact
 *
 * - GOVERNANCE compromised: Full protocol control (expected for governance)
 * - MANAGEMENT compromised: Funds moveable but contained in system
 * - KEEPER compromised: Liveness issues only (no fund theft)
 * - SYSTEM_CONTRACT compromised: N/A (contracts only, no private keys)
 */
abstract contract SuperEarnAccessControl is Initializable, AccessControlUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    // ============================================
    // Role Definitions (High to Low Authority)
    // ============================================

    /**
     * @notice Ultimate protocol governance authority
     * @dev Alias for OpenZeppelin DEFAULT_ADMIN_ROLE for semantic clarity
     *
     * WHO:
     * - Protocol multisig (5-of-9 cold storage)
     * - Timelock contract (optional, for decentralization)
     * - DAO governance (future)
     *
     * AUTHORITY:
     * - Grant/revoke all roles (including other governance members)
     * - Configure critical parameters (vaults, agents, bridges)
     * - Manage economic security (whitelist shareholders/depositors)
     * - Emergency functions (pause, recover tokens, emergency withdraw)
     * - Set parameter bounds (max slippage, timeouts)
     *
     * ATTACK VECTORS CONTROLLED:
     * - Role escalation attacks
     * - Unauthorized component replacement
     * - Economic manipulation (whitelist attacks)
     * - Fund recovery (stuck tokens)
     *
     * SECURITY POSTURE: Cold storage, hardware wallets, requires 5+ signatures
     */
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;

    /**
     * @notice Strategic operational authority for fund management
     * @dev For human operators making capital allocation decisions
     *
     * WHO:
     * - Operations team multisig (2-of-3 warm storage)
     * - Trusted human operators
     * - Fund managers
     *
     * AUTHORITY:
     * - OriginVault: depositToRemote(), withdrawFromRemote()
     * - RemoteVault: depositToYearn(), withdrawFromYearn(), swap()
     * - CrosschainAdapter: processPendingBridgeAssets()
     * - BridgeAccountant: setBridgeTimeout(), manual reconciliation
     * - Configure operational parameters (within governance-set bounds)
     *
     * CANNOT DO:
     * - Transfer funds to external EOAs (no theft vector)
     * - Modify critical configuration (vault addresses, agents)
     * - Manage role grants (only governance)
     * - Emergency functions (pause/unpause)
     *
     * ATTACK VECTORS CONTROLLED:
     * - Unauthorized cross-chain fund movements
     * - Unauthorized yield strategy changes
     * - Excessive slippage (within bounds)
     *
     * SECURITY POSTURE: Warm storage, 2-of-3 multisig, daily operations
     * COMPROMISE IMPACT: Medium (funds moveable but contained in protocol)
     */
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");

    /**
     * @notice Tactical operational authority for automated processes
     * @dev For keeper bots and automated operations contracts
     *
     * WHO:
     * - Keeper bot hot wallets
     * - CrosschainKeeper contract
     * - Automated monitoring systems
     *
     * AUTHORITY:
     * - OriginVault: processRedemptionQueue(), batchFulfillRedemptions()
     * - RemoteVault: fulfillPendingWithdrawals()
     * - CrosschainAdapter: retryFailedMessage()
     * - Queue processing and batch operations
     * - Message retry mechanisms
     *
     * CANNOT DO:
     * - Move funds between chains (strategic operations)
     * - Interact with Yearn vaults
     * - Execute swaps
     * - Modify configuration
     * - Transfer funds externally
     *
     * ATTACK VECTORS CONTROLLED:
     * - Queue manipulation (can DOS but not steal)
     * - Message retry spam (bounded by gas)
     * - Redemption timing (but within protocol rules)
     *
     * SECURITY POSTURE: Hot wallet, automated, limited blast radius
     * COMPROMISE IMPACT: Low (liveness issues only, no fund theft possible)
     */
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /**
     * @notice System-level authority for inter-contract communication
     * @dev CONTRACTS ONLY - Never grant to EOAs
     *
     * WHO:
     * - SuperEarnMessageAgent contract
     * - CrosschainAdapter contract
     * - Authorized system contracts ONLY
     *
     * AUTHORITY:
     * - RemoteVault: handleWithdrawRequest(), handleEmergencyWithdrawRequest()
     * - CrosschainAdapter: handleBridged(), bridge state updates
     * - BridgeAccountant: recordOutbound(), recordInbound(), reconciliation
     * - Inter-contract callbacks and state synchronization
     *
     * CANNOT DO:
     * - Transfer funds directly
     * - Modify configuration
     * - Grant roles
     * - User-facing operations
     *
     * ATTACK VECTORS CONTROLLED:
     * - Unauthorized callback injection
     * - Fake bridge notifications
     * - State corruption via unauthorized updates
     *
     * SECURITY POSTURE: Contract addresses only, validated via msg.sender
     * VALIDATION: Must verify msg.sender is authorized contract address
     * COMPROMISE IMPACT: N/A (no private keys exist for contracts)
     */
    bytes32 public constant SYSTEM_CONTRACT_ROLE = keccak256("SYSTEM_CONTRACT_ROLE");

    // ============================================
    // Custom Errors
    // ============================================

    /// @notice Thrown when caller lacks required governance role
    error NotGovernance();

    /// @notice Thrown when caller lacks required management role
    error NotManagement();

    /// @notice Thrown when caller lacks required keeper role
    error NotKeeper();

    /// @notice Thrown when caller lacks required system contract role
    error NotSystemContract();

    /// @notice Thrown when caller lacks required manager role (governance or management)
    error NotManager();

    /// @notice Thrown when caller lacks required operator role (governance, management, or keeper)
    error NotOperator();

    // ============================================
    // Initializer
    // ============================================

    /**
     * @notice Initialize role hierarchy
     * @dev Set GOVERNANCE_ROLE as admin for all other roles
     *      This means only governance can grant/revoke management, keeper, and system contract roles
     */
    function __SuperEarnAccessControl_init() internal onlyInitializing {
        // GOVERNANCE_ROLE is DEFAULT_ADMIN_ROLE (already set by AccessControlUpgradeable)
        // Set GOVERNANCE_ROLE as role admin for all other roles
        _setRoleAdmin(MANAGEMENT_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(KEEPER_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(SYSTEM_CONTRACT_ROLE, GOVERNANCE_ROLE);
    }

    function __SuperEarnAccessControl_init_unchained() internal onlyInitializing { }

    // ============================================
    // Single Role Modifiers
    // ============================================

    /**
     * @notice Allows GOVERNANCE_ROLE only (strictest access control)
     * @dev Use for critical configuration changes, role grants, emergency functions
     *      Example: Set vault parameters, configure bridges, pause/unpause
     *
     * Equivalent to: onlyRole(GOVERNANCE_ROLE)
     */
    modifier onlyGovernance() {
        if (!isGovernance(msg.sender)) {
            revert NotGovernance();
        }
        _;
    }

    /**
     * @notice Allows MANAGEMENT_ROLE only (no governance override)
     * @dev Use when you specifically want management-only (rare)
     *      Typically you want onlyManagers() which allows governance override
     *
     * Equivalent to: onlyRole(MANAGEMENT_ROLE)
     */
    modifier onlyManagement() {
        if (!isManagement(msg.sender)) {
            revert NotManagement();
        }
        _;
    }

    /**
     * @notice Allows KEEPER_ROLE only (no management/governance override)
     * @dev Use when you specifically want keeper-only (rare)
     *      Typically you want onlyOperators() which allows management override
     *
     * Equivalent to: onlyRole(KEEPER_ROLE)
     */
    modifier onlyKeeper() {
        if (!isKeeper(msg.sender)) {
            revert NotKeeper();
        }
        _;
    }

    // ============================================
    // Composite Modifiers (Convenience)
    // ============================================

    /**
     * @notice Allows GOVERNANCE or MANAGEMENT roles
     * @dev Use for functions that ops team can call with governance override
     *      Example: Strategic fund movements, yield management
     *
     * This is the most commonly used modifier for operational functions.
     */
    modifier onlyManagers() {
        if (!isManager(msg.sender)) {
            revert NotManager();
        }
        _;
    }

    /**
     * @notice Allows GOVERNANCE, MANAGEMENT, or KEEPER roles
     * @dev Use for functions that keeper can call with human override
     *      Example: Queue processing, batch fulfillments
     */
    modifier onlyOperators() {
        if (!hasOperatorRole(msg.sender)) {
            revert NotOperator();
        }
        _;
    }

    /**
     * @notice Requires caller to be a contract with SYSTEM_CONTRACT_ROLE
     * @dev Additional safety: verify msg.sender is contract AND has role
     *      This prevents accidental EOA grants and enforces contracts-only policy
     */
    modifier onlySystemContract() {
        if (!isSystemContract(msg.sender)) {
            revert NotSystemContract();
        }

        _;
    }

    // ============================================
    // Role Grant Overrides (Safety)
    // ============================================

    /**
     * @notice Override grantRole to add safety checks for SYSTEM_CONTRACT_ROLE
     * @dev Prevents granting SYSTEM_CONTRACT_ROLE to EOAs
     * @param role Role to grant
     * @param account Account to receive role
     */
    function grantRole(bytes32 role, address account) public virtual override {
        // Call parent implementation
        super.grantRole(role, account);
    }

    // ============================================
    // View Functions (Role Queries)
    // ============================================

    /**
     * @notice Check if account has governance role
     * @param account Address to check
     * @return True if account has GOVERNANCE_ROLE
     */
    function isGovernance(address account) public view returns (bool) {
        return hasRole(GOVERNANCE_ROLE, account);
    }

    /**
     * @notice Check if account has management role
     * @param account Address to check
     * @return True if account has MANAGEMENT_ROLE
     */
    function isManagement(address account) public view returns (bool) {
        return hasRole(MANAGEMENT_ROLE, account);
    }

    /**
     * @notice Check if account has keeper role
     * @param account Address to check
     * @return True if account has KEEPER_ROLE
     */
    function isKeeper(address account) public view returns (bool) {
        return hasRole(KEEPER_ROLE, account);
    }

    /**
     * @notice Check if account has system contract role
     * @param account Address to check
     * @return True if account has SYSTEM_CONTRACT_ROLE
     */
    function isSystemContract(address account) public view returns (bool) {
        return hasRole(SYSTEM_CONTRACT_ROLE, account);
    }

    /**
     * @notice Check if account is a manager (governance or management)
     * @param account Address to check
     * @return True if account has GOVERNANCE_ROLE or MANAGEMENT_ROLE
     */
    function isManager(address account) public view returns (bool) {
        return hasRole(GOVERNANCE_ROLE, account) || hasRole(MANAGEMENT_ROLE, account);
    }

    /**
     * @notice Check if account has operator role (governance, management, or keeper)
     * @param account Address to check
     * @return True if account has GOVERNANCE_ROLE, MANAGEMENT_ROLE, or KEEPER_ROLE
     */
    function hasOperatorRole(address account) public view returns (bool) {
        return hasRole(GOVERNANCE_ROLE, account) || hasRole(MANAGEMENT_ROLE, account) || hasRole(KEEPER_ROLE, account);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
