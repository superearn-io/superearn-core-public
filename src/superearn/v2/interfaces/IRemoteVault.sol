// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { ICrosschainVault } from "./ICrosschainVault.sol";

/**
 * @title IRemoteVault
 * @notice Interface for remote vaults in the crosschain architecture
 * @dev Extends ICrosschainVault with remote-specific operations
 *      Remote vaults:
 *      - Manage yield generation strategies (e.g., Yearn)
 *      - Handle USDC/USDT swaps for withdrawals
 *      - Process deposit and withdrawal requests from origin
 *      - Report asset status back to origin
 */
interface IRemoteVault is ICrosschainVault {
    // ============================================
    // View Functions
    // ============================================

    /**
     * @notice Get idle USDC balance
     * @return Amount of idle USDC in the vault
     */
    function idleUsdc() external view returns (uint256);

    /**
     * @notice Get idle USDT balance
     * @return Amount of idle USDT in the vault
     */
    function idleUsdt() external view returns (uint256);

    /**
     * @notice Get total idle assets (USDC + USDT equivalent)
     * @return Total idle assets in USDC terms
     */
    function idleAssets() external view returns (uint256);

    /**
     * @notice Get total assets under management
     * @dev Includes idle USDC, USDT, Yearn position, and balances in transit to origin
     * @return Total assets in USDC terms
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Get unfulfilled withdrawal info
     * @return Amount of withdrawals pending fulfillment (in USDT)
     */
    function getUnfulfilledWithdrawalInfo() external view returns (uint256);

    /**
     * @notice Get amount that can be fulfilled now with available balance
     * @return Amount that can be fulfilled
     */
    function fulfillableAmount() external view returns (uint256);

    // ============================================
    // Keeper Functions
    // ============================================

    /// @notice Address of the USDC Yearn vault
    function usdcYearnVault() external view returns (address);

    /// @notice Address of the USDT Yearn vault
    function usdtYearnVault() external view returns (address);

    /**
     * @notice Deposit to Yearn vault
     * @dev Called by keeper to deposit idle assets to Yearn
     * @param amount Amount to deposit (0 for all available)
     * @param isUsdc True for USDC vault, false for USDT vault
     */
    function depositToYearn(uint256 amount, bool isUsdc) external;

    /**
     * @notice Withdraw yVault shares from Yearn vault
     * @dev Called by keeper to redeem yVault shares (assets delivered after cooldown)
     * @param yShares Amount of yVault shares to redeem
     * @param isUsdc True for USDC vault, false for USDT vault
     * @return assetAmountOut Asset tokens withdrawn immediately (likely 0 until claim)
     * @return cooldownRequestId Cooldown request ID for tracking redemption
     * @return ySharesRedeemed Actual yVault shares redeemed (after clamping to balance)
     */
    function withdrawFromYearn(
        uint256 yShares,
        bool isUsdc
    )
        external
        returns (uint256 assetAmountOut, uint256 cooldownRequestId, uint256 ySharesRedeemed);

    /**
     * @notice Swap USDC to USDT or USDT to USDC via Uniswap V3
     * @dev Called by keeper before fulfilling withdrawals
     * @param isUsdtToUsdc True if swapping USDT to USDC, false if swapping USDC to USDT
     * @param amount Amount of tokens to swap
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @param fee Uniswap V3 pool fee tier (e.g., 100=0.01%, 500=0.05%, 3000=0.3%)
     * @return amountOut Amount of tokens received
     */
    function swapUniswap(
        bool isUsdtToUsdc,
        uint256 amount,
        uint256 minAmountOut,
        uint24 fee
    )
        external
        returns (uint256 amountOut);

    /**
     * @notice Swap USDC to USDT or USDT to USDC via Curve
     * @dev Called by keeper before fulfilling withdrawals
     * @param isUsdtToUsdc True if swapping USDT to USDC, false if swapping USDC to USDT
     * @param amount Amount of tokens to swap
     * @param minAmountOut Minimum amount to receive (slippage protection)
     * @return amountOut Amount of tokens received
     */
    function swapCurve(bool isUsdtToUsdc, uint256 amount, uint256 minAmountOut) external returns (uint256 amountOut);

    /**
     * @notice Fulfill pending withdrawals
     * @dev Called by keeper to process withdrawal requests from Yearn
     * @return fulfilledUsdt USDT amount successfully fulfilled
     */
    function fulfillPendingWithdrawals() external returns (uint256 fulfilledUsdt);

    /**
     * @notice Emergency withdraw from Yearn
     * @dev Called by keeper or admin in emergency situations
     * @param maxLoss Maximum acceptable loss in basis points
     * @param isUsdc True for USDC vault, false for USDT vault
     */
    function emergencyWithdrawFromYearn(uint256 maxLoss, bool isUsdc) external;

    /**
     * @notice Emergency function to redeem CooldownVault shares
     * @dev Directly calls CooldownVault.redeem() with this vault's shares
     * @param isUsdc True for USDC vault, false for USDT vault
     * @return requestId The redemption request ID
     */
    function emergencyCooldownVaultRedeem(bool isUsdc) external returns (uint256 requestId);

    /**
     * @notice Emergency function to claim a CooldownVault redemption
     * @param requestId The redemption request ID to claim
     * @param maxLossBps Maximum acceptable loss in basis points
     * @param isUsdc True for USDC vault, false for USDT vault
     * @return claimableAssets The amount of assets claimed
     */
    function emergencyCooldownVaultClaim(
        uint256 requestId,
        uint256 maxLossBps,
        bool isUsdc
    )
        external
        returns (uint256 claimableAssets);

    // ============================================
    // Agent Callbacks (for crosschain messages)
    // ============================================

    /**
     * @notice Handle withdrawal request from origin
     * @dev Called by agent when receiving WITHDRAW message
     * @param usdtAmount Amount of USDT requested by origin
     * @return nonce Bridge operation nonce if fulfilled, 0 if unfulfilled
     */
    function handleWithdrawRequest(uint256 usdtAmount) external returns (uint256 nonce);

    // ============================================
    // Custom Strategy Operations
    // ============================================

    function depositToCustomStrategy(address strategy, address token, uint256 amount) external;

    function withdrawFromCustomStrategy(
        address strategy,
        address token,
        uint256 amount
    )
        external
        returns (uint256 actual);
}
