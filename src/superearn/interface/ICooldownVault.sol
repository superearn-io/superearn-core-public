// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

import { IERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/interfaces/IERC4626Upgradeable.sol";
import { IGeneralHealthCheck } from "@superearn/interface/IHealthCheck.sol";

interface ICooldownVault is IERC4626Upgradeable {
    struct RedeemRequest {
        address receiver;
        uint256 assets;
        uint256 cooldownRequestedTime;
        uint256 cooldownPeriod; // Stored cooldown period at request time
        // Note: claimableAt could be derived as (cooldownRequestedTime + cooldownPeriod),
        // but both fields are kept separately for frontend logging and diagnostics.
        bool claimed;
    }

    struct PredepositRequest {
        address strategy;
        uint256 shares;
        uint256 debtAssets;
        uint256 cooldownRequestedTime;
        uint256 cooldownPeriod;
        bool claimed;
    }

    event RedeemRequested(
        address indexed caller,
        address indexed receiver,
        uint256 indexed requestId,
        uint256 assets,
        uint256 shares,
        uint256 requestedTime
    );
    event Claimed(address indexed caller, uint256 indexed requestId, uint256 assets, uint256 claimable);
    event InstantRedemption(address indexed caller, uint256 shares, uint256 assets);
    event CooldownPeriodUpdated(uint256 newCooldownPeriod);
    event CooldownPeriodSubmitted(uint256 newCooldownPeriod);
    event GovernanceTransferred(address indexed previousGovernance, address indexed newGovernance);
    event GovernanceTransferSubmitted(address indexed newGovernance);
    event UpdateManagement(address indexed newManagement);
    event Recovered(address indexed to, uint256 assets);
    event RecoverClaimLoss(address indexed to, uint256 shares);
    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event PredepositRequested(
        address indexed strategy,
        uint256 indexed predepositId,
        uint256 shares,
        uint256 debtAssets,
        uint256 cooldownPeriod
    );
    event DebtRetrieved(
        address indexed strategy, uint256 indexed predepositId, uint256 debtAssets, uint256 debtPayment
    );
    event MaxLossThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event StrangeCooldownPeriod(uint256 maxCooldownPeriod, uint256 newCooldownPeriod);
    event SetDoHealthCheck(bool doHealthCheck);
    event HealthCheckUpdated(address indexed oldHealthCheck, address indexed newHealthCheck);
    event StrategyDebtShortfall(address indexed strategy, uint256 indexed predepositId, uint256 shortfall);
    event StrategyDebtRepaid(address indexed strategy, uint256 repay, uint256 remainingShortfall);
    event AuthorizedAddressAdded(address indexed authorizedAddress);
    event AuthorizedAddressRemoved(address indexed authorizedAddress);
    event RedeemReceiverUpdated(uint256 indexed requestId, address indexed oldReceiver, address indexed newReceiver);

    // ERC4626 Core Functions (inherited from IERC4626)
    // function asset() external view returns (address);
    // function totalAssets() external view returns (uint256);
    // function convertToShares(uint256 assets) external view returns (uint256);
    // function convertToAssets(uint256 shares) external view returns (uint256);
    // function maxDeposit(address receiver) external view returns (uint256);
    // function previewDeposit(uint256 assets) external view returns (uint256);
    // function deposit(uint256 assets, address receiver) external returns (uint256);
    // function maxMint(address receiver) external view returns (uint256);
    // function previewMint(uint256 shares) external view returns (uint256);
    // function mint(uint256 shares, address receiver) external returns (uint256);
    // function maxWithdraw(address owner) external view returns (uint256);
    // function previewWithdraw(uint256 assets) external view returns (uint256);
    // function withdsraw(uint256 assets, address receiver, address owner) external returns (uint256);
    // function maxRedeem(address owner) external view returns (uint256);
    // function previewRedeem(uint256 shares) external view returns (uint256);
    // function redeem(uint256 shares, address receiver, address owner) external returns (uint256);

    // ERC20 Functions (inherited from IERC20 through IERC4626)
    // function totalSupply() external view returns (uint256);
    // function balanceOf(address account) external view returns (uint256);
    // function transfer(address to, uint256 amount) external returns (bool);
    // function allowance(address owner, address spender) external view returns (uint256);
    // function approve(address spender, uint256 amount) external returns (bool);
    // function transferFrom(address from, address to, uint256 amount) external returns (bool);

    // ERC20Metadata Functions (inherited from IERC20Metadata through IERC4626)
    // function name() external view returns (string memory);
    // function symbol() external view returns (string memory);
    // function decimals() external view returns (uint8);

    // CooldownVault specific functions
    function claim(uint256 requestId, uint256 maxLossBps) external returns (uint256 claimable);
    function updateRedeemReceiver(uint256 requestId, address newReceiver) external;
    function instantRedeem(uint256 shares) external returns (uint256 assets);
    function predeposit(uint256 assets) external returns (uint256 predepositId, uint256 shares);
    function retrieveDebt(uint256 predepositId) external;
    function retrieveShortfall(uint256 assets) external;

    // Governance and management
    function cooldownPeriod() external view returns (uint256 period);
    function governance() external view returns (address governanceAddress);
    function pendingGovernance() external view returns (address pendingAddress);
    function management() external view returns (address managementAddress);

    function doHealthCheck() external view returns (bool);
    function healthCheck() external view returns (IGeneralHealthCheck healthCheckAddress);
    function submitGovernanceTransfer(address newGovernance) external;
    function acceptGovernanceTransfer() external;
    function setManagement(address newManagement) external;

    function recover() external returns (uint256 assets);
    function recoverClaimLoss() external returns (uint256 shares);
    function submitCooldownPeriod(uint256 _cooldownPeriod) external;
    function acceptCooldownPeriod() external;
    function pause() external;
    function unpause() external;
    function setMaxLossThresholdBps(uint256 _maxLossThresholdBps) external;
    function setDoHealthCheck(bool newDoHealthCheck) external;
    function setHealthCheck(address newHealthCheck) external;

    // Strategy management
    function addStrategy(address strategy) external;
    function removeStrategy(address strategy) external;
    function isStrategy(address strategy) external view returns (bool result);
    function getStrategies() external view returns (address[] memory strategies);

    // Authorized addresses
    function getAuthorizedAddresses() external view returns (address[] memory authorizedAddresses);
    function addAuthorizedAddress(address authorizedAddress) external;
    function removeAuthorizedAddress(address authorizedAddress) external;

    // View functions - State variables
    function lastRequestId() external view returns (uint256 requestId);
    function lastPredepositId() external view returns (uint256 predepositId);
    function pendingCooldownPeriod() external view returns (uint256 period);
    function hasPendingCooldownPeriod() external view returns (bool hasPending);
    function totalDebt() external view returns (uint256 debt);
    function totalLockedAssets() external view returns (uint256 lockedAssets);
    function maxLossThresholdBps() external view returns (uint256 thresholdBps);
    function accRedeemRequestedAmount(uint256 requestId) external view returns (uint256 amount);
    function accClaimedAmount() external view returns (uint256 amount);

    // View functions - Computed values
    function assetBalance() external view returns (uint256 balance);
    function idleBalance() external view returns (uint256 idle);
    function strategyShortfall(address strategy) external view returns (uint256 outstanding);
    function strategyDebtOutstanding(address strategy) external view returns (uint256 outstanding);
    function pendingAssets(address receiver) external view returns (uint256 pending);
    function maxInstantRedeem(address caller) external view returns (uint256 maxShares);

    // View functions - Request tracking
    function getRedeemRequest(uint256 requestId) external view returns (RedeemRequest memory request);
    function getPredepositRequest(uint256 predepositId) external view returns (PredepositRequest memory request);
    function getUnclaimedRedeemRequestIds() external view returns (uint256[] memory requestIds);
    function getUnclaimedRedeemRequestIds(
        uint256 limit,
        uint256 skip
    )
        external
        view
        returns (uint256[] memory requestIds);
    function getUnclaimedPredepositRequestIds() external view returns (uint256[] memory requestIds);
    function getUnclaimedPredepositRequestIds(
        uint256 limit,
        uint256 skip
    )
        external
        view
        returns (uint256[] memory requestIds);
    function redeemRequests(uint256 requestId)
        external
        view
        returns (address receiver, uint256 assets, uint256 cooldownRequestedTime, uint256 cooldownPeriod, bool claimed);
    function predepositRequests(uint256 predepositId)
        external
        view
        returns (
            address strategy,
            uint256 shares,
            uint256 debtAssets,
            uint256 cooldownRequestedTime,
            uint256 cooldownPeriod,
            bool claimed
        );
}
