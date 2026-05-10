// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

interface IStrategyCooldownAware {
    // Events
    event Preminted(
        uint256 indexed predepositId, uint256 debtAssets, uint256 predepositedShares, uint256 externalRedeemIndex
    );
    event PredepositDebtRepaid(uint256 indexed predepositId, uint256 repayAmount);
    event AdjustPosition(
        uint256 utilizationRateBps,
        uint256 filledUnderlyingAmount,
        uint256 unfilledUnderlyingAmount,
        uint256 estimatedTotalAssets
    );
    event RemainingPredepositDebtRepaid(uint256 amount);
    event ShortfallToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);

    // Core functions
    function getRedeemDetail(uint256 redeemIndex)
        external
        view
        returns (
            uint256 redeemId,
            uint256 redeemTimestamp,
            address redeemUser,
            uint256 redeemUnderlyingAmount,
            bool redeemIsDone
        );
    function isPredepositAlreadyClaimed(uint256 predepositId) external view returns (bool isClaimed);
    function predepositDebtRetrievable(uint256 predepositId) external view returns (bool isRetrievable);
    function repayPredepositDebt(uint256 predepositId) external returns (uint256 repayAmount);
    function externalRedeemIndexes(uint256 predepositId) external view returns (uint256);
    function getUtilizationRate() external view returns (uint256);

    // Additional view functions
    function getCooldownPeriod() external view returns (uint256 cooldownPeriod);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function getSupplyCap() external view returns (uint256 supplyAssetsCap, uint256 availableAssets);

    // Governance execution functions
    function emergencyRedeem(uint256 shares)
        external
        returns (bool success, uint256 redeemId, uint256 redeemUnderlyingAmount, uint256 cooldownPeriod);
    function emergencyClaim(uint256 redeemIndex) external returns (bool success, uint256 claimedAmount);
    function submitExecution(address[] calldata targets, bytes[] calldata calldatas) external;
    function acceptExecution() external returns (bool success, bytes memory returnData);
    function cancelExecution() external;
    function setAllowedTarget(address target, bool allowed) external;
}
