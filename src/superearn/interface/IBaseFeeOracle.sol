// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

interface IBaseFee {
    function basefee_global() external view returns (uint256);
}

interface IBaseFeeOracle {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}
