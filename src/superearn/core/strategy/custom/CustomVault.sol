// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ICustomStrategy } from "@superearn/v2/interfaces/ICustomStrategy.sol";

/**
 * @title CustomVault
 * @notice ERC4626 vault on Kaia holding USDT as base asset, with CustomStrategy registration
 * @dev Only the designated customYearnStrategy can deposit/hold shares.
 *      CustomStrategy contracts are registered and managed by governance.
 *      Operators can deposit/withdraw tokens to/from registered CustomStrategies.
 *      Upgradeable via TransparentUpgradeableProxy.
 */
contract CustomVault is Initializable, ERC4626Upgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    error OnlyCustomYearnStrategy();
    error OnlyGovernance();
    error OnlyPendingGovernance();
    error OnlyOperator();
    error ZeroAddress();
    error InvalidStrategyAddress();
    error CustomStrategyAlreadyRegistered(address strategy);
    error CustomStrategyNotRegistered(address strategy);
    error CustomStrategyHasAssets(address strategy, uint256 assets);
    error AmountMustBeGreaterThanZero();
    error InvalidToken(address token);
    error CustomYearnStrategyAlreadySet();

    // ============================================
    // EVENTS
    // ============================================

    event CustomStrategyAdded(address indexed strategy);
    event CustomStrategyRemoved(address indexed strategy);
    event DepositedToCustomStrategy(address indexed strategy, address indexed token, uint256 amount);
    event WithdrawnFromCustomStrategy(address indexed strategy, address indexed token, uint256 actual);
    event OperatorUpdated(address indexed operator, bool allowed);
    event GovernanceTransferSubmitted(address indexed pendingGovernance);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event CustomYearnStrategyMigrated(address indexed oldStrategy, address indexed newStrategy);
    event CustomYearnStrategySet(address indexed strategy);

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The only address allowed to deposit/hold shares
    address public customYearnStrategy;

    /// @notice Governance address
    address public governance;

    /// @notice Pending governance for two-step transfer
    address public pendingGovernance;

    /// @notice Registered custom strategies
    address[] public customStrategies;

    /// @notice Whether an address is a registered custom strategy
    mapping(address => bool) public isCustomStrategy;

    /// @dev Index+1 for swap-and-pop removal (0 = not registered)
    mapping(address => uint256) private __customStrategyIndex;

    /// @notice Operator addresses for depositTo/withdrawFrom CustomStrategy
    mapping(address => bool) public operators;

    /// @dev Reserved storage gap for future upgrades (50 total slots - 7 used = 43)
    uint256[43] private __gap;

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyCustomYearnStrategy() {
        if (msg.sender != customYearnStrategy) revert OnlyCustomYearnStrategy();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != governance) revert OnlyOperator();
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
     * @notice Initialize the CustomVault
     * @param _asset USDT token address (underlying asset)
     * @param _governance Governance address
     * @param _name ERC20 share token name
     * @param _symbol ERC20 share token symbol
     */
    function initialize(
        address _asset,
        address _governance,
        string calldata _name,
        string calldata _symbol
    )
        external
        initializer
    {
        if (_asset == address(0)) revert ZeroAddress();
        if (_governance == address(0)) revert ZeroAddress();

        __ERC4626_init(IERC20Upgradeable(_asset));
        __ERC20_init(_name, _symbol);
        __ReentrancyGuard_init();

        governance = _governance;
    }

    // ============================================
    // ERC4626 OVERRIDES (access control)
    // ============================================

    /// @dev Only customYearnStrategy can deposit
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        onlyCustomYearnStrategy
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @dev Only customYearnStrategy can mint
    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        onlyCustomYearnStrategy
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @dev Only customYearnStrategy can withdraw
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override
        onlyCustomYearnStrategy
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev Only customYearnStrategy can redeem
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override
        onlyCustomYearnStrategy
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    // ============================================
    // ERC4626 OVERRIDES (totalAssets)
    // ============================================

    /**
     * @notice Total assets = idle USDT + sum of all custom strategy totalAssets
     * @dev All custom strategies must denominate in USDT (same as vault asset)
     */
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20Upgradeable(asset()).balanceOf(address(this));
        uint256 length = customStrategies.length;
        for (uint256 i = 0; i < length; i++) {
            total += ICustomStrategy(customStrategies[i]).totalAssets();
        }
        return total;
    }

    // ============================================
    // CUSTOM STRATEGY MANAGEMENT
    // ============================================

    /**
     * @notice Register a new custom strategy
     * @param strategy Address of the custom strategy to add
     */
    function addCustomStrategy(address strategy) external onlyGovernance {
        if (strategy == address(0)) revert InvalidStrategyAddress();
        if (isCustomStrategy[strategy]) revert CustomStrategyAlreadyRegistered(strategy);

        // Verify strategy points to this vault — prevents registering unusable
        // strategies whose onlyRemoteVault modifier would reject calls from here.
        if (ICustomStrategy(strategy).remoteVault() != address(this)) {
            revert InvalidStrategyAddress();
        }

        // Verify denomination token is the same as vault asset
        address denomToken = ICustomStrategy(strategy).denominationToken();
        if (denomToken != asset()) {
            revert InvalidStrategyAddress();
        }

        // Verify strategy has no assets
        uint256 strategyAssets = ICustomStrategy(strategy).totalAssets();
        if (strategyAssets > 0) revert CustomStrategyHasAssets(strategy, strategyAssets);

        // Add to array and mappings
        customStrategies.push(strategy);
        isCustomStrategy[strategy] = true;
        __customStrategyIndex[strategy] = customStrategies.length; // Store index+1

        emit CustomStrategyAdded(strategy);
    }

    /**
     * @notice Remove a custom strategy
     * @dev Strategy must have totalAssets == 0 to be removed
     * @param strategy Address of the custom strategy to remove
     */
    function removeCustomStrategy(address strategy) external onlyGovernance {
        if (!isCustomStrategy[strategy]) revert CustomStrategyNotRegistered(strategy);

        // Verify strategy has no assets (use try/catch so governance can remove broken strategies)
        try ICustomStrategy(strategy).totalAssets() returns (uint256 strategyAssets) {
            if (strategyAssets > 0) revert CustomStrategyHasAssets(strategy, strategyAssets);
        } catch {
            // Strategy reverted — allow removal so governance can recover
        }

        // Swap-and-pop removal
        uint256 indexPlusOne = __customStrategyIndex[strategy];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = customStrategies.length - 1;

        if (index != lastIndex) {
            address lastStrategy = customStrategies[lastIndex];
            customStrategies[index] = lastStrategy;
            __customStrategyIndex[lastStrategy] = indexPlusOne;
        }

        customStrategies.pop();
        delete isCustomStrategy[strategy];
        delete __customStrategyIndex[strategy];

        emit CustomStrategyRemoved(strategy);
    }

    /**
     * @notice Deposit tokens to a custom strategy
     * @param strategy Address of the custom strategy
     * @param token Token to deposit
     * @param amount Amount to deposit
     */
    function depositToCustomStrategy(
        address strategy,
        address token,
        uint256 amount
    )
        external
        onlyOperator
        nonReentrant
    {
        if (!isCustomStrategy[strategy]) revert CustomStrategyNotRegistered(strategy);
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (token != asset()) revert InvalidToken(token);

        IERC20(token).forceApprove(strategy, amount);
        ICustomStrategy(strategy).deposit(token, amount);
        // Reset residual allowance to minimize authorization attack surface
        IERC20(token).forceApprove(strategy, 0);

        emit DepositedToCustomStrategy(strategy, token, amount);
    }

    /**
     * @notice Withdraw tokens from a custom strategy
     * @param strategy Address of the custom strategy
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @return actual Amount actually withdrawn
     */
    function withdrawFromCustomStrategy(
        address strategy,
        address token,
        uint256 amount
    )
        external
        onlyOperator
        nonReentrant
        returns (uint256 actual)
    {
        if (!isCustomStrategy[strategy]) revert CustomStrategyNotRegistered(strategy);
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (token != asset()) revert InvalidToken(token);

        actual = ICustomStrategy(strategy).withdraw(token, amount);

        emit WithdrawnFromCustomStrategy(strategy, token, actual);
    }

    // ============================================
    // GOVERNANCE FUNCTIONS
    // ============================================

    /**
     * @notice Set operator status for an address
     * @param operator Address to update
     * @param allowed Whether the address should be an operator
     */
    function setOperator(address operator, bool allowed) external onlyGovernance {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    /**
     * @notice Initiate governance transfer (two-step)
     * @param newGovernance Address of the new governance
     */
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        pendingGovernance = newGovernance;
        emit GovernanceTransferSubmitted(newGovernance);
    }

    /**
     * @notice Accept governance transfer
     */
    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert OnlyPendingGovernance();

        address oldGovernance = governance;
        governance = pendingGovernance;
        pendingGovernance = address(0);

        emit GovernanceTransferred(oldGovernance, governance);
    }

    /**
     * @notice Set the CustomYearnStrategy address (one-time, governance only)
     * @dev Resolves the circular bootstrap dependency: CustomVault can be initialized first,
     *      then CustomYearnStrategy deployed (reading CustomVault.asset()), and finally
     *      governance calls this function to bind them together.
     *      Can only be called once (when customYearnStrategy is address(0)).
     *      After initial binding, use migrateCustomYearnStrategy() for changes.
     * @param _customYearnStrategy Address of the CustomYearnStrategy
     */
    function setCustomYearnStrategy(address _customYearnStrategy) external onlyGovernance {
        if (_customYearnStrategy == address(0)) revert ZeroAddress();
        if (customYearnStrategy != address(0)) revert CustomYearnStrategyAlreadySet();

        customYearnStrategy = _customYearnStrategy;

        emit CustomYearnStrategySet(_customYearnStrategy);
    }

    /**
     * @notice Atomically hand off authority to a new CustomYearnStrategy during migration
     * @dev Called by the current strategy from prepareMigration() so that share custody and
     *      execution authority are transferred in the same transaction, preventing a state
     *      where the new strategy holds shares but cannot call deposit/withdraw/redeem.
     * @param newStrategy Address of the successor CustomYearnStrategy
     */
    function migrateCustomYearnStrategy(address newStrategy) external onlyCustomYearnStrategy {
        if (newStrategy == address(0)) revert ZeroAddress();

        address oldStrategy = customYearnStrategy;
        customYearnStrategy = newStrategy;

        emit CustomYearnStrategyMigrated(oldStrategy, newStrategy);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get the number of registered custom strategies
     * @return Number of strategies
     */
    function customStrategyCount() external view returns (uint256) {
        return customStrategies.length;
    }

    /**
     * @notice Get all registered custom strategies
     * @return Array of strategy addresses
     */
    function getCustomStrategies() external view returns (address[] memory) {
        return customStrategies;
    }
}
