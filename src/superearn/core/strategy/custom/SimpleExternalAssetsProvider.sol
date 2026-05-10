// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IExternalAssetsProvider } from "@superearn/v2/interfaces/IExternalAssetsProvider.sol";

/**
 * @title SimpleExternalAssetsProvider
 * @notice External assets provider that tracks multiple token balances at a strategy address
 * @dev Returns totalAssets as the sum of all tracked token balances, normalized to
 *      the denomination token's decimals at a 1:1 rate. Suitable for stablecoin-only
 *      strategies where tokens are pegged (e.g., USDT + USDe).
 *      No oracle dependency — purely balance-based tracking.
 */
contract SimpleExternalAssetsProvider is IExternalAssetsProvider {
    // ============================================
    // ERRORS
    // ============================================

    error ZeroAddress();
    error EmptyTokenList();

    // ============================================
    // IMMUTABLE STORAGE
    // ============================================

    /// @notice The strategy address whose balances to track
    address public immutable STRATEGY;

    /// @notice The denomination token (totalAssets denominated in this token's decimals)
    address public immutable DENOMINATION_TOKEN;

    /// @notice Denomination token decimals (cached at deploy time)
    uint8 public immutable DENOM_DECIMALS;

    // ============================================
    // STORAGE
    // ============================================

    /// @notice Tracked tokens and their decimal adjustment factors
    address[] public trackedTokens;

    /// @notice Pre-computed: 10 ** |tokenDecimals - denomDecimals| for each tracked token
    uint256[] public decimalFactors;

    /// @notice 1 = token has MORE decimals than denom (divide), 0 = equal, 2 = FEWER (multiply)
    uint8[] public decimalOps;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Deploy the provider
     * @param _strategy The strategy address whose balances to track
     * @param _denominationToken The token used for denomination (e.g., USDT)
     * @param _tokens Tokens to track at the strategy address (e.g., [USDT, USDe])
     */
    constructor(address _strategy, address _denominationToken, address[] memory _tokens) {
        if (_strategy == address(0)) revert ZeroAddress();
        if (_denominationToken == address(0)) revert ZeroAddress();
        if (_tokens.length == 0) revert EmptyTokenList();

        STRATEGY = _strategy;
        DENOMINATION_TOKEN = _denominationToken;
        DENOM_DECIMALS = IERC20Metadata(_denominationToken).decimals();

        for (uint256 i = 0; i < _tokens.length; i++) {
            if (_tokens[i] == address(0)) revert ZeroAddress();
            trackedTokens.push(_tokens[i]);

            uint8 tokenDecimals = IERC20Metadata(_tokens[i]).decimals();
            if (tokenDecimals > DENOM_DECIMALS) {
                decimalFactors.push(10 ** (tokenDecimals - DENOM_DECIMALS));
                decimalOps.push(1); // divide
            } else if (tokenDecimals < DENOM_DECIMALS) {
                decimalFactors.push(10 ** (DENOM_DECIMALS - tokenDecimals));
                decimalOps.push(2); // multiply
            } else {
                decimalFactors.push(1);
                decimalOps.push(0); // no adjustment
            }
        }
    }

    // ============================================
    // IExternalAssetsProvider
    // ============================================

    /// @inheritdoc IExternalAssetsProvider
    function denominationToken() external view override returns (address) {
        return DENOMINATION_TOKEN;
    }

    /// @inheritdoc IExternalAssetsProvider
    function getTotalAssets() external view override returns (uint256 totalAssets) {
        for (uint256 i = 0; i < trackedTokens.length; i++) {
            uint256 balance = IERC20(trackedTokens[i]).balanceOf(STRATEGY);
            if (balance == 0) continue;

            uint8 op = decimalOps[i];
            if (op == 1) {
                // Token has more decimals → divide to normalize
                totalAssets += balance / decimalFactors[i];
            } else if (op == 2) {
                // Token has fewer decimals → multiply to normalize
                totalAssets += balance * decimalFactors[i];
            } else {
                // Same decimals
                totalAssets += balance;
            }
        }
    }

    // ============================================
    // VIEW HELPERS
    // ============================================

    /// @notice Get the number of tracked tokens
    function trackedTokenCount() external view returns (uint256) {
        return trackedTokens.length;
    }

    /// @notice Get balance of a specific tracked token at the strategy
    function getTokenBalance(uint256 index) external view returns (address token, uint256 balance) {
        token = trackedTokens[index];
        balance = IERC20(token).balanceOf(STRATEGY);
    }
}
