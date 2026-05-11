// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Strategy Parameters Struct
struct StrategyParams {
    uint256 performanceFee; // Strategist's fee (basis points)
    uint256 activation; // Activation block.timestamp
    uint256 debtRatio; // Maximum borrow amount (in BPS of total assets)
    uint256 minDebtPerHarvest; // Lower limit on the increase of debt since last harvest
    uint256 maxDebtPerHarvest; // Upper limit on the increase of debt since last harvest
    uint256 lastReport; // block.timestamp of the last time a report occurred
    uint256 totalDebt; // Total outstanding debt that Strategy has
    uint256 totalGain; // Total returns that Strategy has realized for Vault
    uint256 totalLoss; // Total losses that Strategy has realized for Vault
}

/**
 * @title IVault
 * @notice Interface for Yearn Vault contract
 * @dev This interface corresponds to Vault.vy version 0.4.6 (the `apiVersion()` reported by the in-scope deployed Yearn V2 vaults)
 */
interface IVault is IERC20 {
    // Vault Events
    event Deposit(address indexed recipient, uint256 shares, uint256 amount);
    event Withdraw(address indexed recipient, uint256 shares, uint256 amount);
    event Sweep(address indexed token, uint256 amount);
    event LockedProfitDegradationUpdated(uint256 value);

    // Strategy Events
    event StrategyAdded(
        address indexed strategy,
        uint256 debtRatio,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 performanceFee
    );
    event StrategyReported(
        address indexed strategy,
        uint256 gain,
        uint256 loss,
        uint256 debtPaid,
        uint256 totalGain,
        uint256 totalLoss,
        uint256 totalDebt,
        uint256 debtAdded,
        uint256 debtRatio
    );
    event FeeReport(uint256 management_fee, uint256 performance_fee, uint256 strategist_fee, uint256 duration);
    event WithdrawFromStrategy(address indexed strategy, uint256 totalDebt, uint256 loss);
    event StrategyUpdateDebtRatio(address indexed strategy, uint256 debtRatio);
    event StrategyUpdateMinDebtPerHarvest(address indexed strategy, uint256 minDebtPerHarvest);
    event StrategyUpdateMaxDebtPerHarvest(address indexed strategy, uint256 maxDebtPerHarvest);
    event StrategyUpdatePerformanceFee(address indexed strategy, uint256 performanceFee);
    event StrategyMigrated(address indexed oldVersion, address indexed newVersion);
    event StrategyRevoked(address indexed strategy);
    event StrategyRemovedFromQueue(address indexed strategy);
    event StrategyAddedToQueue(address indexed strategy);

    // Governance Events
    event UpdateGovernance(address governance);
    event UpdateManagement(address management);
    event UpdateRewards(address rewards);
    event UpdateDepositLimit(uint256 depositLimit);
    event UpdatePerformanceFee(uint256 performanceFee);
    event UpdateManagementFee(uint256 managementFee);
    event UpdateGuardian(address guardian);
    event EmergencyShutdown(bool active);
    event UpdateWithdrawalQueue(address[20] queue);
    event NewPendingGovernance(address indexed pendingGovernance);

    // ERC20 View functions for public variables
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function totalSupply() external view returns (uint256);

    // Vault View functions for public variables
    function token() external view returns (address);
    function governance() external view returns (address);
    function management() external view returns (address);
    function guardian() external view returns (address);
    function strategies(address) external view returns (StrategyParams memory);
    function withdrawalQueue(uint256) external view returns (address);
    function emergencyShutdown() external view returns (bool);
    function depositLimit() external view returns (uint256);
    function debtRatio() external view returns (uint256);
    function totalIdle() external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function lastReport() external view returns (uint256);
    function activation() external view returns (uint256);
    function lockedProfit() external view returns (uint256);
    function lockedProfitDegradation() external view returns (uint256);
    function rewards() external view returns (address);
    function managementFee() external view returns (uint256);
    function performanceFee() external view returns (uint256);
    function nonces(address) external view returns (uint256);

    // Initialization
    function initialize(
        address token,
        address governance,
        address rewards,
        string memory nameOverride,
        string memory symbolOverride,
        address guardian,
        address management
    )
        external;

    // Core functions
    function apiVersion() external pure returns (string memory);
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    // ERC20 functions
    function transfer(address receiver, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function increaseAllowance(address spender, uint256 amount) external returns (bool);
    function decreaseAllowance(address spender, uint256 amount) external returns (bool);
    function permit(
        address owner,
        address spender,
        uint256 amount,
        uint256 expiry,
        bytes memory signature
    )
        external
        returns (bool);

    // Vault core functions
    function totalAssets() external view returns (uint256);

    // NOTE: Vyper produces multiple signatures for a given function with "default" args
    function deposit() external returns (uint256);
    function deposit(uint256 amount) external returns (uint256);
    function deposit(uint256 _amount, address recipient) external returns (uint256);

    // NOTE: Vyper produces multiple signatures for a given function with "default" args
    function withdraw() external returns (uint256);
    function withdraw(uint256 maxShares) external returns (uint256);
    function withdraw(uint256 maxShares, address recipient) external returns (uint256);
    function withdraw(uint256 maxShares, address recipient, uint256 maxLossBps) external returns (uint256);

    function pricePerShare() external view returns (uint256);
    function maxAvailableShares() external view returns (uint256);
    function availableDepositLimit() external view returns (uint256);

    // Strategy functions
    function debtOutstanding() external view returns (uint256);
    function debtOutstanding(address strategy) external view returns (uint256);

    function creditAvailable() external view returns (uint256);
    function creditAvailable(address strategy) external view returns (uint256);

    function expectedReturn() external view returns (uint256);
    function expectedReturn(address strategy) external view returns (uint256);

    function report(uint256 gain, uint256 loss, uint256 _debtPayment) external returns (uint256);

    // Governance functions
    function setName(string memory name) external;
    function setSymbol(string memory symbol) external;
    function setGovernance(address governance) external;
    function acceptGovernance() external;
    function setManagement(address management) external;
    function setRewards(address rewards) external;
    function setLockedProfitDegradation(uint256 degradation) external;
    function setDepositLimit(uint256 limit) external;
    function setPerformanceFee(uint256 fee) external;
    function setManagementFee(uint256 fee) external;
    function setGuardian(address guardian) external;
    function setEmergencyShutdown(bool active) external;
    function setWithdrawalQueue(address[20] memory queue) external;

    // Strategy management functions
    function addStrategy(
        address strategy,
        uint256 debtRatio,
        uint256 minDebtPerHarvest,
        uint256 maxDebtPerHarvest,
        uint256 performanceFee
    )
        external;
    function updateStrategyDebtRatio(address strategy, uint256 debtRatio) external;
    function updateStrategyMinDebtPerHarvest(address strategy, uint256 minDebtPerHarvest) external;
    function updateStrategyMaxDebtPerHarvest(address strategy, uint256 maxDebtPerHarvest) external;
    function updateStrategyPerformanceFee(address strategy, uint256 performanceFee) external;
    function migrateStrategy(address oldVersion, address newVersion) external;

    function revokeStrategy() external;
    function revokeStrategy(address strategy) external;

    function addStrategyToQueue(address strategy) external;
    function removeStrategyFromQueue(address strategy) external;

    // Utility functions
    function sweep(address token, uint256 amount) external;
}
