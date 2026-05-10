// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title IERC6900ExecutionHookLightModule
 * @notice Execution hook interface following ERC-6900 standard
 * @dev Matches ERC-6900 IExecutionHookModule signature exactly.
 *      For non-AA contracts, `value` parameter can be passed as 0.
 */
interface IERC6900ExecutionHookLightModule {
    /**
     * @notice Run the pre execution hook specified by the `entityId`
     * @dev To indicate the entire call should revert, the function MUST revert.
     * @param entityId An identifier that routes the call to different internal implementations,
     *        should there be more than one.
     * @param sender The caller address.
     * @param value The call value (pass 0 for ERC20-based operations).
     * @param data The calldata sent.
     * @return Context to pass to a post execution hook, if present. An empty bytes array MAY be returned.
     */
    function preExecutionHook(
        uint32 entityId,
        address sender,
        uint256 value,
        bytes calldata data
    ) external returns (bytes memory);

    /**
     * @notice Run the post execution hook specified by the `entityId`
     * @dev To indicate the entire call should revert, the function MUST revert.
     * @param entityId An identifier that routes the call to different internal implementations,
     *        should there be more than one.
     * @param preExecHookData The context returned by its associated pre execution hook.
     */
    function postExecutionHook(
        uint32 entityId,
        bytes calldata preExecHookData
    ) external;
}
