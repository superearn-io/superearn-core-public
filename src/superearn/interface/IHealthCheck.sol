// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

interface IHealthCheck {
    // Events
    event GovernanceUpdated(address indexed newGovernance);
    event ManagementUpdated(address indexed newManagement);
    event DefaultProfitLimitUpdated(uint256 newProfitLimitRatio);
    event DefaultLossLimitUpdated(uint256 newLossLimitRatio);
    event StrategyLimitsUpdated(
        address indexed strategy, uint256 profitLimitRatio, uint256 lossLimitRatio, bool exists
    );
    event CustomCheckUpdated(address indexed strategy, address indexed customCheck);

    function check(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding,
        uint256 totalDebt
    )
        external
        view
        returns (bool);
}

interface IStrategyHealthCheck {
    function check(
        uint256 profit,
        uint256 loss,
        uint256 debtPayment,
        uint256 debtOutstanding,
        uint256 totalDebt,
        address callerStrategy
    )
        external
        view
        returns (bool);
}

interface IGeneralHealthCheck {
    function check() external view returns (bool);
}

interface IGeneralHealthCheckLogic {
    function check(address caller) external view returns (bool);
}
