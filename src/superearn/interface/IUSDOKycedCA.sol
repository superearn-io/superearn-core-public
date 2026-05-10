// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUSDOExpressV2 } from "@superearn/api/USDOExpressV2API.sol";
import { IHealthCheck } from "@superearn/interface/IHealthCheck.sol";

interface IUSDOKycedCA {
    // ============ Structs ============
    struct RedeemRequest {
        address strategy;
        uint256 usdoAmt;
        uint256 usdcPreviewed;
        uint256 usdcReceived;
        uint256 cooldownRequestedTime;
        uint256 cooldownPeriod;
        bool claimed;
    }

    // ============ Events ============
    event Deposited(address indexed strategy, uint256 usdcAmount, uint256 usdoReceived);
    event RedeemRequested(
        uint256 indexed requestId, address indexed strategy, uint256 usdoAmt, uint256 usdcPreviewed, bytes32 queueHashId
    );
    event RedeemQueuedAllFailed(uint256 dustFreeAmount, uint256 fallbackAmount);
    event Claimed(address indexed caller, uint256 indexed requestId, uint256 usdoAmt, uint256 usdcReceived);
    event RedeemQueued(uint256 usdoAmount, uint256 usdcAmtPreviewed, bytes32 queueHashId);
    event ExcessUsdoRecovered(address indexed to, uint256 amount);
    event CooldownPeriodUpdated(uint256 newCooldownPeriod);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event GovernanceTransferSubmitted(address indexed newGovernance);
    event GovernanceTransferred(address indexed oldGovernance, address indexed newGovernance);
    event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);
    event Recovered(address indexed to, uint256 usdcAmount);
    event SetDoHealthCheck(bool doHealthCheck);
    event HealthCheckUpdated(address indexed oldHealthCheck, address indexed newHealthCheck);
    event HistoricalMinRedeemAmtSynced(uint256 newMinAmt);
    event HooksUpdated(address indexed oldHooks, address indexed newHooks);

    // ============ Core Functions ============
    function deposit(uint256 usdcAmt, address receiver) external returns (uint256 usdoAmt);
    function redeem(uint256 usdoAmt, address owner) external returns (uint256 requestId);
    function claim(uint256 redeemRequestId) external;

    // ============ View Functions - State Variables ============
    function governance() external view returns (address);
    function pendingGovernance() external view returns (address);
    function usdoExpress() external view returns (IUSDOExpressV2);
    function usdc() external view returns (IERC20);
    function usdo() external view returns (IERC20);
    function redeemRequests(uint256 requestId)
        external
        view
        returns (
            address strategy,
            uint256 usdoAmt,
            uint256 usdcPreviewed,
            uint256 usdcReceived,
            uint256 cooldownRequestedTime,
            uint256 cooldownPeriod,
            bool claimed
        );
    function accRedeemRequestedPreviewedAmt(uint256 requestId) external view returns (uint256);
    function lastRedeemRequestId() external view returns (uint256);
    function cooldownPeriod() external view returns (uint256);
    function doHealthCheck() external view returns (bool);
    function healthCheck() external view returns (IHealthCheck);
    function hooks() external view returns (address);
    function totalRedeemedUsdoAmt() external view returns (uint256);
    function accClaimedPreviewedAmt() external view returns (uint256);

    // ============ View Functions - Computed Values ============
    function totalRedeemedUsdcAmt() external view returns (uint256);
    function previewDeposit(uint256 usdcAmt) external view returns (uint256 usdoAmt);
    function previewMint(uint256 usdoAmt) external view returns (uint256 usdcAmt);
    function previewRedeem(uint256 usdoAmt) external view returns (uint256 usdcAmt);
    function previewWithdraw(uint256 usdcAmt) external view returns (uint256 usdoAmt);
    function isKyced() external view returns (bool);
    function getQueuedRedemption() external view returns (uint256 queuedUsdoAmt);
    function minDeposit() external view returns (uint256);
    function minMint() external view returns (uint256);
    function minRedeem() external view returns (uint256);
    function isClaimable(uint256 redeemRequestId) external view returns (bool);
    function isStrategy(address strategy) external view returns (bool);
    function getStrategies() external view returns (address[] memory);
    function getUnclaimedRedeemRequestIds() external view returns (uint256[] memory);
    function getUnclaimedRedeemRequestCount() external view returns (uint256);
}
