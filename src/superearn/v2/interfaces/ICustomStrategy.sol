// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title ICustomStrategy
 * @notice Interface for custom strategies managed by RemoteVault
 * @dev Custom strategies receive multiple token types and report totalAssets in a denomination token
 */
interface ICustomStrategy {
    // ============================================
    // EVENTS
    // ============================================

    event Deposited(address indexed token, uint256 amount);
    event Withdrawn(address indexed token, uint256 amount, address indexed receiver);
    event DepositTokenSet(address indexed token, bool allowed);
    event WithdrawTokenSet(address indexed token, bool allowed);

    // ============================================
    // ERRORS
    // ============================================

    error TokenNotAllowedForDeposit(address token);
    error TokenNotAllowedForWithdraw(address token);
    error InsufficientBalance(address token, uint256 available, uint256 requested);
    error OnlyRemoteVault();

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Token used as denomination for totalAssets() calculation
     * @dev RemoteVault uses this to convert strategy value to its base asset
     * @return Token address used for denomination
     */
    function denominationToken() external view returns (address);

    /**
     * @notice Total assets in this strategy, denominated in denominationToken
     * @dev Value is retrieved from ExternalAssetsProvider
     * @return Total assets value
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Check if a token is allowed for deposit
     * @param token Token address to check
     * @return True if token is allowed for deposit
     */
    function isDepositToken(address token) external view returns (bool);

    /**
     * @notice Check if a token is allowed for withdrawal
     * @param token Token address to check
     * @return True if token is allowed for withdrawal
     */
    function isWithdrawToken(address token) external view returns (bool);

    /**
     * @notice Get the RemoteVault address that manages this strategy
     * @return RemoteVault address
     */
    function remoteVault() external view returns (address);

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Deposit tokens into the strategy
     * @dev Only callable by RemoteVault. Token must be in allowedDepositTokens.
     * @param token Token address to deposit
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) external;

    /**
     * @notice Withdraw tokens from the strategy
     * @dev Only callable by RemoteVault. Token must be in allowedWithdrawTokens.
     * @param token Token address to withdraw
     * @param amount Amount to withdraw
     * @return actual Amount actually withdrawn
     */
    function withdraw(address token, uint256 amount) external returns (uint256 actual);

    /**
     * @notice Execute arbitrary calls to allowed external contracts
     * @dev Only callable by strategist or governance.
     *      Validates targets are allowed and assets change is within tolerance.
     * @param targets Array of contract addresses to call
     * @param calldatas Array of encoded function call data
     */
    function submitExecution(address[] calldata targets, bytes[] calldata calldatas) external;
}
