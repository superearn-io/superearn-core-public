// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ICurvePool
 * @notice Interface for Curve StableSwap pools (including StableSwap-NG)
 * @dev Used for stablecoin swaps with minimal slippage
 *
 * Note: Legacy Curve pools (e.g., 3pool) don't return values from exchange().
 * Newer StableSwap-NG pools return the output amount.
 * Use balance delta measurement for compatibility with legacy pools.
 */
interface ICurvePool {
    /**
     * @notice Perform a token swap
     * @dev Legacy pools don't return a value; newer pools return the output amount
     * @param i Index of the input token in the pool
     * @param j Index of the output token in the pool
     * @param dx Amount of input token to swap
     * @param min_dy Minimum amount of output token to receive
     */
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;

    /**
     * @notice Calculate the expected output amount for a swap
     * @param i Index of the input token in the pool
     * @param j Index of the output token in the pool
     * @param dx Amount of input token
     * @return Expected amount of output token
     */
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /**
     * @notice Get the address of a token in the pool by index
     * @param index Token index in the pool
     * @return Token address
     */
    function coins(uint256 index) external view returns (address);
}

