// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title IExternalAssetsProvider
 * @notice Interface for external contracts that provide totalAssets calculation for CustomStrategy
 * @dev Implementation should calculate total value of all assets managed by the strategy
 *      and return the value denominated in the provider's denomination token.
 *      The CustomStrategy will validate that the denomination token matches its own.
 */
interface IExternalAssetsProvider {
    /**
     * @notice Returns the denomination token used by this provider
     * @dev The CustomStrategy will verify this matches its own denominationToken
     * @return The denomination token address
     */
    function denominationToken() external view returns (address);

    /**
     * @notice Returns total assets value denominated in the provider's denominationToken
     * @dev This function should aggregate all positions, balances, and pending values
     *      that belong to the strategy and convert them to the denomination token
     * @return totalAssets Total assets value in denomination token units
     */
    function getTotalAssets() external view returns (uint256 totalAssets);
}
