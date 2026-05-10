// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title IRunespearReceiver
 * @notice Interface for RunespearReceiver view functions
 * @dev Used by keepers to access defensive message handling functions
 */
interface IRunespearReceiver {
    /**
     * @notice Get all failed message IDs
     * @return Array of failed message IDs (empty if none)
     */
    function getFailedMessageIds() external view returns (bytes32[] memory);

    /**
     * @notice Get failed message details
     * @param messageId CCIP message ID
     * @return Source chain ID
     * @return Error bytes from catch block
     * @return When the failure occurred
     */
    function getFailedMessageDetails(bytes32 messageId) external view returns (uint256, bytes memory, uint256);
}
