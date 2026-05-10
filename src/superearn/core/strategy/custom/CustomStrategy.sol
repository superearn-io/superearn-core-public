// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IExternalAssetsProvider } from "@superearn/v2/interfaces/IExternalAssetsProvider.sol";
import { ICustomStrategy } from "@superearn/v2/interfaces/ICustomStrategy.sol";

/**
 * @title CustomStrategy
 * @notice Custom strategy for manual protocol management via RemoteVault
 * @dev Upgradeable via TransparentUpgradeableProxy
 *      - Receives multiple token types from RemoteVault
 *      - Reports totalAssets via ExternalAssetsProvider
 *      - Strategist can execute arbitrary calls to allowed targets
 */
contract CustomStrategy is ICustomStrategy, Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============================================
    // CONSTANTS
    // ============================================

    uint256 public constant BPS = 10_000;
    /// @dev increaseAllowance(address,uint256) selector - not in standard IERC20
    bytes4 private constant _INCREASE_ALLOWANCE_SELECTOR = 0x39509351;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Token used for totalAssets denomination
    address public denominationToken;
    /// @notice RemoteVault that manages this strategy
    address public remoteVault;
    /// @notice Governance address
    address public governance;
    /// @notice Pending governance address for 2-step transfer
    address public pendingGovernance;
    /// @notice Strategist address (can execute operations)
    address public strategist;
    /// @notice External contract that provides totalAssets calculation
    IExternalAssetsProvider public externalAssetsProvider;
    /// @notice Tolerance for assets change during execution (in BPS)
    uint256 public assetsChangeTolerance;

    /// @notice Tokens allowed for deposit
    mapping(address => bool) public allowedDepositTokens;
    /// @notice Tokens allowed for withdrawal
    mapping(address => bool) public allowedWithdrawTokens;
    /// @notice Allowed target contracts for execution
    mapping(address => bool) public allowedTargets;
    /// @notice Tracks tokens that have been approved to each spender for automatic revocation
    mapping(address => EnumerableSet.AddressSet) private _approvedTokensBySpender;
    /// @notice Reverse mapping: tracks spenders that have been approved on each token
    mapping(address => EnumerableSet.AddressSet) private _spendersByToken;
    /// @notice Per-target function selector whitelist for execution validation
    mapping(address => mapping(bytes4 => bool)) public allowedSelectors;
    /// @notice Bitmap of parameter indices requiring address validation (bit N = check param at offset N*32)
    mapping(address => mapping(bytes4 => uint256)) public paramCheckBitmap;
    /// @notice Allowed address values per {target, selector, paramIndex}
    mapping(address => mapping(bytes4 => mapping(uint256 => mapping(address => bool)))) public allowedDestinations;

    // ============================================
    // EVENTS (not in ICustomStrategy)
    // ============================================

    event ExternalAssetsProviderSet(address indexed oldProvider, address indexed newProvider);
    event StrategistSet(address indexed oldStrategist, address indexed newStrategist);
    event GovernanceTransferSubmitted(address indexed pendingGovernance);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event ExecutionSubmitted(address[] targets, bytes[] calldatas);
    event TargetAllowlistUpdated(address indexed target, bool allowed);
    event AssetsChangeToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);
    event AllowanceRevoked(address indexed spender, address indexed token);
    event SelectorAllowlistUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event ParamCheckUpdated(address indexed target, bytes4 indexed selector, uint256 paramIndex, bool enabled);
    event DestinationAllowlistUpdated(
        address indexed target, bytes4 indexed selector, uint256 paramIndex, address destination, bool allowed
    );

    // ============================================
    // ERRORS (not in ICustomStrategy)
    // ============================================

    error ExternalAssetsProviderNotSet();
    error AssetsValueMismatch(uint256 oldValue, uint256 newValue);
    error DenominationTokenMismatch(address expected, address actual);
    error ZeroAddress();
    error OnlyGovernance();
    error OnlyPendingGovernance();
    error NoPendingGovernance();
    error OnlyStrategist();
    error InvalidExecutionState(string reason);
    error ExecutionFailed(uint256 index, bytes returnData);
    error AssetsChangeExceedsTolerance(uint256 before, uint256 after_, uint256 toleranceBps);
    error ToleranceTooHigh(uint256 provided, uint256 max);
    error SpenderNotAllowed(address spender);
    error RecipientNotAllowed(address recipient);
    error ERC20CallFailed(uint256 index);
    error SelectorNotAllowed(address target, bytes4 selector);
    error DestinationNotAllowed(address target, bytes4 selector, uint256 paramIndex, address destination);

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    modifier onlyStrategist() {
        if (msg.sender != strategist && msg.sender != governance) revert OnlyStrategist();
        _;
    }

    modifier onlyRemoteVault() {
        if (msg.sender != remoteVault) revert OnlyRemoteVault();
        _;
    }

    // ============================================
    // INITIALIZER
    // ============================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the custom strategy
     * @param _governance Governance address
     * @param _remoteVault RemoteVault address
     * @param _denominationToken Token for totalAssets denomination
     * @param _strategist Strategist address (can be zero, defaults to governance)
     * @param _assetsChangeTolerance Tolerance for assets change during execution (in BPS, max 1%)
     */
    function initialize(
        address _governance,
        address _remoteVault,
        address _denominationToken,
        address _strategist,
        uint256 _assetsChangeTolerance
    )
        external
        initializer
    {
        if (_governance == address(0)) revert ZeroAddress();
        if (_remoteVault == address(0)) revert ZeroAddress();
        if (_denominationToken == address(0)) revert ZeroAddress();
        if (_assetsChangeTolerance > BPS) {
            revert ToleranceTooHigh(_assetsChangeTolerance, BPS);
        }

        __ReentrancyGuard_init();

        governance = _governance;
        remoteVault = _remoteVault;
        denominationToken = _denominationToken;
        strategist = _strategist != address(0) ? _strategist : _governance;
        assetsChangeTolerance = _assetsChangeTolerance;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get total assets from external provider
     * @dev Verifies that the provider's denomination token matches this strategy's denominationToken
     * @return Total assets value in denomination token units
     */
    function totalAssets() public view returns (uint256) {
        if (address(externalAssetsProvider) == address(0)) {
            return 0;
        }

        // Verify denomination token matches
        address providerDenomToken = externalAssetsProvider.denominationToken();
        if (providerDenomToken != denominationToken) {
            revert DenominationTokenMismatch(denominationToken, providerDenomToken);
        }

        return externalAssetsProvider.getTotalAssets();
    }

    /**
     * @notice Check if a token is allowed for deposit
     * @param token Token address to check
     * @return True if token is allowed
     */
    function isDepositToken(address token) external view returns (bool) {
        return allowedDepositTokens[token];
    }

    /**
     * @notice Check if a token is allowed for withdrawal
     * @param token Token address to check
     * @return True if token is allowed
     */
    function isWithdrawToken(address token) external view returns (bool) {
        return allowedWithdrawTokens[token];
    }

    // ============================================
    // REMOTE VAULT FUNCTIONS
    // ============================================

    /**
     * @notice Deposit tokens into the strategy
     * @dev Only callable by RemoteVault
     * @param token Token address to deposit
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) external onlyRemoteVault nonReentrant {
        if (!allowedDepositTokens[token]) {
            revert TokenNotAllowedForDeposit(token);
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposited(token, amount);
    }

    /**
     * @notice Withdraw tokens from the strategy
     * @dev Only callable by RemoteVault
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     * @return actual Amount actually withdrawn
     */
    function withdraw(address token, uint256 amount) external onlyRemoteVault nonReentrant returns (uint256 actual) {
        if (!allowedWithdrawTokens[token]) {
            revert TokenNotAllowedForWithdraw(token);
        }

        uint256 balance = IERC20(token).balanceOf(address(this));
        actual = amount > balance ? balance : amount;

        if (actual == 0) {
            revert InsufficientBalance(token, balance, amount);
        }

        IERC20(token).safeTransfer(msg.sender, actual);

        emit Withdrawn(token, actual, msg.sender);

        return actual;
    }

    // ============================================
    // STRATEGIST FUNCTIONS
    // ============================================

    /**
     * @notice Execute arbitrary calls to allowed external contracts
     * @dev Validates targets are allowed and assets change is within tolerance (before vs after)
     * @param targets Array of contract addresses to call
     * @param calldatas Array of encoded function call data
     */
    function submitExecution(
        address[] calldata targets,
        bytes[] calldata calldatas
    )
        external
        onlyStrategist
        nonReentrant
    {
        _validateTargetsAndCalldatas(targets, calldatas);

        uint256 assetsBefore = totalAssets();
        _executeBatch(targets, calldatas);
        _validateAssetsChange(assetsBefore, totalAssets(), assetsChangeTolerance);

        emit ExecutionSubmitted(targets, calldatas);
    }

    /**
     * @notice Execute arbitrary calls with expected balance validation
     * @dev For operations that cause large asset changes (e.g., reward claims).
     *      Validates actual post-execution totalAssets against the provided expected value
     *      within tolerance, instead of comparing before vs after.
     * @param targets Array of contract addresses to call
     * @param calldatas Array of encoded function call data
     * @param expectedAssetsAfter Expected totalAssets after execution
     */
    function submitExecutionWithExpectedBalance(
        address[] calldata targets,
        bytes[] calldata calldatas,
        uint256 expectedAssetsAfter
    )
        external
        onlyStrategist
        nonReentrant
    {
        _validateTargetsAndCalldatas(targets, calldatas);

        uint256 assetsBefore = totalAssets();
        _executeBatch(targets, calldatas);
        uint256 assetsAfter = totalAssets();

        // Hard floor: assets must not decrease from pre-execution level
        if (assetsAfter < assetsBefore) {
            revert AssetsChangeExceedsTolerance(assetsBefore, assetsAfter, assetsChangeTolerance);
        }
        // Validate actual assets match caller's expectation within tolerance
        _validateAssetsChange(expectedAssetsAfter, assetsAfter, assetsChangeTolerance);

        emit ExecutionSubmitted(targets, calldatas);
    }

    // ============================================
    // GOVERNANCE FUNCTIONS
    // ============================================

    /**
     * @notice Set external assets provider with validation
     * @dev Validates that:
     *      1. New provider's denomination token matches strategy's denominationToken
     *      2. Old and new provider return same totalAssets value (if old provider exists)
     *      This is to prevent totalAssets() from suddenly increasing, and to ensure
     *      that no untracked assets are introduced before the assetProvider is ready.
     * @param newProvider New provider address
     */
    function setExternalAssetsProvider(address newProvider) external onlyGovernance {
        if (newProvider == address(0)) revert ZeroAddress();

        // Validate denomination token matches
        address providerDenomToken = IExternalAssetsProvider(newProvider).denominationToken();
        if (providerDenomToken != denominationToken) {
            revert DenominationTokenMismatch(denominationToken, providerDenomToken);
        }

        address oldProvider = address(externalAssetsProvider);

        // If there's an existing provider, validate values match
        // Use try/catch on old provider so governance can replace a permanently reverting provider
        if (oldProvider != address(0)) {
            try externalAssetsProvider.getTotalAssets() returns (uint256 oldValue) {
                uint256 newValue = IExternalAssetsProvider(newProvider).getTotalAssets();
                if (oldValue != newValue) {
                    revert AssetsValueMismatch(oldValue, newValue);
                }
            } catch {
                // Old provider reverted - allow replacement so governance can recover
            }
        }

        externalAssetsProvider = IExternalAssetsProvider(newProvider);

        emit ExternalAssetsProviderSet(oldProvider, newProvider);
    }

    /**
     * @notice Set allowed deposit token
     * @param token Token address
     * @param allowed Whether token is allowed
     */
    function setDepositToken(address token, bool allowed) external onlyGovernance {
        if (token == address(0)) revert ZeroAddress();
        allowedDepositTokens[token] = allowed;
        emit DepositTokenSet(token, allowed);
    }

    /**
     * @notice Set allowed withdraw token
     * @param token Token address
     * @param allowed Whether token is allowed
     */
    function setWithdrawToken(address token, bool allowed) external onlyGovernance {
        if (token == address(0)) revert ZeroAddress();
        allowedWithdrawTokens[token] = allowed;
        emit WithdrawTokenSet(token, allowed);
    }

    /**
     * @notice Set strategist address
     * @param newStrategist New strategist address
     */
    function setStrategist(address newStrategist) external onlyGovernance {
        if (newStrategist == address(0)) revert ZeroAddress();
        address oldStrategist = strategist;
        strategist = newStrategist;
        emit StrategistSet(oldStrategist, newStrategist);
    }

    /**
     * @notice Submit governance transfer (step 1/2)
     * @param newGovernance New governance address
     */
    function submitGovernanceTransfer(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        pendingGovernance = newGovernance;
        emit GovernanceTransferSubmitted(newGovernance);
    }

    /**
     * @notice Accept governance transfer (step 2/2)
     * @dev Must be called by the pending governance address
     */
    function acceptGovernanceTransfer() external {
        if (pendingGovernance == address(0)) revert NoPendingGovernance();
        if (msg.sender != pendingGovernance) revert OnlyPendingGovernance();

        address oldGovernance = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);

        emit GovernanceTransferred(oldGovernance, governance);
    }

    /**
     * @notice Add or remove a target address from the allowlist
     * @param target The address to update
     * @param allowed Whether the target should be allowed
     */
    function setAllowedTarget(address target, bool allowed) external onlyGovernance {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this)) revert InvalidExecutionState("CANNOT_ALLOW_SELF");
        allowedTargets[target] = allowed;

        // Revoke all outstanding ERC20 allowances when removing a target
        if (!allowed) {
            // Case 1: target is a spender — revoke all token allowances granted to it
            _revokeAllowancesForSpender(target);
            // Case 2: target is a token — revoke all spender allowances on it
            _revokeAllowancesForToken(target);
        }

        emit TargetAllowlistUpdated(target, allowed);
    }

    /**
     * @notice Set the assets change tolerance
     * @param toleranceBps Tolerance in basis points (max 10% = 1000 BPS)
     */
    function setAssetsChangeTolerance(uint256 toleranceBps) external onlyGovernance {
        if (toleranceBps > BPS) {
            revert ToleranceTooHigh(toleranceBps, BPS);
        }
        uint256 oldTolerance = assetsChangeTolerance;
        assetsChangeTolerance = toleranceBps;
        emit AssetsChangeToleranceUpdated(oldTolerance, toleranceBps);
    }

    /**
     * @notice Add or remove an allowed function selector for a specific target
     * @param target The target contract address
     * @param selector The function selector to allow/disallow
     * @param allowed Whether the selector should be allowed
     */
    function setAllowedSelector(address target, bytes4 selector, bool allowed) external onlyGovernance {
        if (target == address(0)) revert ZeroAddress();
        allowedSelectors[target][selector] = allowed;
        emit SelectorAllowlistUpdated(target, selector, allowed);
    }

    /**
     * @notice Batch set allowed function selectors for a specific target
     * @param target The target contract address
     * @param selectors Array of function selectors
     * @param allowed Whether the selectors should be allowed
     */
    function batchSetAllowedSelectors(
        address target,
        bytes4[] calldata selectors,
        bool allowed
    )
        external
        onlyGovernance
    {
        if (target == address(0)) revert ZeroAddress();
        for (uint256 i = 0; i < selectors.length; i++) {
            allowedSelectors[target][selectors[i]] = allowed;
            emit SelectorAllowlistUpdated(target, selectors[i], allowed);
        }
    }

    /**
     * @notice Enable or disable address validation for a specific parameter of a {target, selector} pair
     * @param target The target contract address
     * @param selector The function selector
     * @param paramIndex The parameter index (0-based, e.g., 0 = first param, 1 = second)
     * @param enabled Whether to check this parameter
     */
    function setParamCheck(address target, bytes4 selector, uint256 paramIndex, bool enabled) external onlyGovernance {
        if (paramIndex > 15) revert InvalidExecutionState("PARAM_INDEX_TOO_HIGH");
        if (enabled) {
            paramCheckBitmap[target][selector] |= (1 << paramIndex);
        } else {
            paramCheckBitmap[target][selector] &= ~(1 << paramIndex);
        }
        emit ParamCheckUpdated(target, selector, paramIndex, enabled);
    }

    /**
     * @notice Allow or disallow a destination address for a specific parameter of a {target, selector} pair
     * @param target The target contract address
     * @param selector The function selector
     * @param paramIndex The parameter index (0-based)
     * @param destination The address to allow/disallow for this parameter
     * @param allowed Whether the destination is allowed
     */
    function setAllowedDestination(
        address target,
        bytes4 selector,
        uint256 paramIndex,
        address destination,
        bool allowed
    )
        external
        onlyGovernance
    {
        allowedDestinations[target][selector][paramIndex][destination] = allowed;
        emit DestinationAllowlistUpdated(target, selector, paramIndex, destination, allowed);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Validate targets and calldatas for execution
     * @dev Triad validation: target + selector + destination for every call
     */
    function _validateTargetsAndCalldatas(address[] calldata targets, bytes[] calldata calldatas) internal view {
        if (address(externalAssetsProvider) == address(0)) revert ExternalAssetsProviderNotSet();
        if (targets.length == 0) revert InvalidExecutionState("EMPTY_ARRAYS");
        if (targets.length != calldatas.length) revert InvalidExecutionState("ARRAY_MISMATCH");

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(this)) {
                revert InvalidExecutionState("SELF_CALL_NOT_ALLOWED");
            }
            if (!allowedTargets[targets[i]]) {
                revert InvalidExecutionState("TARGET_NOT_ALLOWED");
            }
            // Triad validation: target + selector + destination parameters
            if (calldatas[i].length >= 4) {
                bytes4 selector = bytes4(calldatas[i]);

                // 1. Validate selector is allowed for this target
                if (!allowedSelectors[targets[i]][selector]) {
                    revert SelectorNotAllowed(targets[i], selector);
                }

                // 2. Hardcoded ERC20 destination checks — always enforced for all strategies
                //    without requiring per-strategy configuration via setParamCheck/setAllowedDestination.
                //    These protect against fund routing via standard ERC20 operations.
                if (calldatas[i].length >= 36) {
                    if (selector == IERC20.approve.selector || selector == _INCREASE_ALLOWANCE_SELECTOR) {
                        address spender = abi.decode(calldatas[i][4:], (address));
                        if (!allowedTargets[spender]) {
                            revert SpenderNotAllowed(spender);
                        }
                    }
                    if (selector == IERC20.transfer.selector) {
                        address to = abi.decode(calldatas[i][4:], (address));
                        if (!allowedTargets[to]) {
                            revert RecipientNotAllowed(to);
                        }
                    }
                    if (selector == IERC20.transferFrom.selector) {
                        (address from, address to) = abi.decode(calldatas[i][4:], (address, address));
                        if (from == address(this) && !allowedTargets[to]) {
                            revert RecipientNotAllowed(to);
                        }
                    }
                }

                // 3. Configurable destination parameter checks using bitmap-driven rules.
                //    Governance can set per-{target, selector} parameter validation via
                //    setParamCheck() and setAllowedDestination() for protocol-specific functions.
                //    Only runs if paramCheckBitmap is configured (default 0 = no additional checks).
                uint256 bitmap = paramCheckBitmap[targets[i]][selector];
                if (bitmap != 0) {
                    for (uint256 paramIdx = 0; paramIdx < 16; paramIdx++) {
                        if (bitmap & (1 << paramIdx) == 0) continue;
                        uint256 offset = 4 + paramIdx * 32;
                        if (calldatas[i].length < offset + 32) break;
                        address dest = abi.decode(calldatas[i][offset:], (address));
                        if (!allowedDestinations[targets[i]][selector][paramIdx][dest]) {
                            revert DestinationNotAllowed(targets[i], selector, paramIdx, dest);
                        }
                    }
                }
            }
        }
    }

    /**
     * @notice Execute a batch of calls
     * @dev For ERC20 calls (transfer, approve, transferFrom), validates return data
     *      to catch tokens that return false instead of reverting on failure.
     */
    function _executeBatch(address[] calldata targets, bytes[] calldata calldatas) internal {
        for (uint256 i = 0; i < targets.length; i++) {
            // Track approve calls for automatic revocation on target removal
            if (calldatas[i].length >= 36) {
                bytes4 selector = bytes4(calldatas[i]);
                if (selector == IERC20.approve.selector || selector == _INCREASE_ALLOWANCE_SELECTOR) {
                    address spender = abi.decode(calldatas[i][4:], (address));
                    // Only track if target is a standard ERC20 (supports allowance())
                    try IERC20(targets[i]).allowance(address(this), spender) {
                        _approvedTokensBySpender[spender].add(targets[i]);
                        _spendersByToken[targets[i]].add(spender);
                    } catch { }
                }
            }

            (bool success, bytes memory returnData) = targets[i].call(calldatas[i]);
            if (!success) {
                revert ExecutionFailed(i, returnData);
            }
            if (_isERC20Call(calldatas[i]) && !_validateERC20ReturnData(returnData)) {
                revert ERC20CallFailed(i);
            }
        }
    }

    /// @dev Check if calldata targets an ERC20 function that returns bool
    function _isERC20Call(bytes calldata data) internal pure returns (bool) {
        if (data.length < 4) return false;
        bytes4 selector = bytes4(data[:4]);
        return selector == IERC20.transfer.selector // 0xa9059cbb
            || selector == IERC20.approve.selector // 0x095ea7b3
            || selector == IERC20.transferFrom.selector; // 0x23b872dd
    }

    /// @dev Validate ERC20 return data: empty (non-standard) or abi-encoded true
    function _validateERC20ReturnData(bytes memory returnData) internal pure returns (bool) {
        return returnData.length == 0 || abi.decode(returnData, (bool));
    }

    /**
     * @notice Validate that assets change is within tolerance
     * @dev Allows both decrease and increase within tolerance
     * @param before Assets before execution
     * @param after_ Assets after execution
     * @param toleranceBps Tolerance in BPS
     */
    function _validateAssetsChange(uint256 before, uint256 after_, uint256 toleranceBps) internal pure {
        if (before == 0 && after_ == 0) return;

        uint256 maxChange;
        if (before > 0) {
            maxChange = (before * toleranceBps) / BPS;
        }

        uint256 actualChange;
        if (after_ > before) {
            actualChange = after_ - before;
        } else {
            actualChange = before - after_;
        }

        if (actualChange > maxChange) {
            revert AssetsChangeExceedsTolerance(before, after_, toleranceBps);
        }
    }

    /**
     * @notice Revoke all tracked ERC20 allowances where target is the spender
     * @param spender The spender address whose allowances should be revoked
     */
    function _revokeAllowancesForSpender(address spender) internal {
        EnumerableSet.AddressSet storage tokens = _approvedTokensBySpender[spender];
        uint256 length = tokens.length();

        for (uint256 i = length; i > 0; i--) {
            address token = tokens.at(i - 1);
            _tryRevokeAllowance(token, spender);
            _spendersByToken[token].remove(spender);
            tokens.remove(token);
        }
    }

    /**
     * @notice Revoke all tracked ERC20 allowances where target is the token
     * @param token The token address whose spender allowances should be revoked
     */
    function _revokeAllowancesForToken(address token) internal {
        EnumerableSet.AddressSet storage spenders = _spendersByToken[token];
        uint256 length = spenders.length();

        for (uint256 i = length; i > 0; i--) {
            address spender = spenders.at(i - 1);
            _tryRevokeAllowance(token, spender);
            _approvedTokensBySpender[spender].remove(token);
            spenders.remove(spender);
        }
    }

    /**
     * @notice Safely attempt to revoke an ERC20 allowance
     * @dev Uses try/catch to handle non-standard tokens that may revert on allowance() or approve()
     */
    function _tryRevokeAllowance(address token, address spender) internal {
        try IERC20(token).allowance(address(this), spender) returns (uint256 currentAllowance) {
            if (currentAllowance > 0) {
                IERC20(token).forceApprove(spender, 0);
                emit AllowanceRevoked(spender, token);
            }
        } catch {
            // Non-standard token — skip silently
        }
    }

    // ============================================
    // STORAGE GAP
    // ============================================

    /**
     * @dev Reserved storage space for future upgrades
     * Current storage layout (15 slots):
     *   - denominationToken: 1 slot
     *   - remoteVault: 1 slot
     *   - governance: 1 slot
     *   - pendingGovernance: 1 slot
     *   - strategist: 1 slot
     *   - externalAssetsProvider: 1 slot
     *   - assetsChangeTolerance: 1 slot
     *   - allowedDepositTokens (mapping): 1 slot
     *   - allowedWithdrawTokens (mapping): 1 slot
     *   - allowedTargets (mapping): 1 slot
     *   - _approvedTokensBySpender (mapping): 1 slot
     *   - _spendersByToken (mapping): 1 slot
     *   - allowedSelectors (nested mapping): 1 slot
     *   - paramCheckBitmap (nested mapping): 1 slot
     *   - allowedDestinations (nested mapping): 1 slot
     * Gap: 50 - 15 = 35
     */
    uint256[35] private __gap;
}
