// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

/**
 * @title TimelockExecutionLib
 * @notice External library for governance timelock execution functions
 * @dev Extracted from BaseCooldownStrategy to reduce contract size.
 *      Uses external functions for separate deployment via DELEGATECALL.
 */
library TimelockExecutionLib {
    using TimelockExecutionLib for TimelockStorage;

    // ============================================
    // STRUCTS
    // ============================================

    /// @notice Pending execution data for timelock
    struct PendingExecution {
        address[] targets;
        bytes[] calldatas;
        uint256 executeAfter;
    }

    // ============================================
    // EVENTS
    // ============================================

    event ExecutionSubmitted(address[] targets, bytes[] calldatas, uint256 executeAfter);
    event ExecutionAccepted(address[] targets, bytes[] calldatas, bytes[] returnData);
    event ExecutionCancelled(address[] targets);
    event TargetAllowlistUpdated(address indexed target, bool allowed);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);

    // ============================================
    // ERRORS
    // ============================================

    error InvalidExecutionState(string reason);
    error ExecutionFailed();

    // ============================================
    // CONSTANTS
    // ============================================

    /// @notice Minimum timelock delay (0 hours)
    uint256 public constant MIN_TIMELOCK_DELAY = 0 hours;
    /// @notice Maximum timelock delay (1 days)
    uint256 public constant MAX_TIMELOCK_DELAY = 1 days;
    /// @notice Execution window duration after timelock expires (7 days)
    uint256 public constant EXECUTION_WINDOW = 7 days;

    // ============================================
    // STORAGE STRUCT
    // ============================================

    /// @notice Storage layout for timelock execution state
    /// @dev Used to pass storage references to library functions
    struct TimelockStorage {
        PendingExecution pendingExecution;
        mapping(address => bool) allowedTargets;
        uint256 timelockDelay;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Submit arbitrary external calls for future execution (supports batch calls)
     * @param self Storage reference to timelock state
     * @param targets Array of contract addresses to call (must be whitelisted, cannot be self)
     * @param calldatas Array of encoded function call data
     * @param allowedSelfCallSelectors such as _setTimelockDelay function (for self-call validation)
     */
    function submitExecution(
        TimelockStorage storage self,
        address[] calldata targets,
        bytes[] calldata calldatas,
        bytes4[] calldata allowedSelfCallSelectors
    )
        external
    {
        // Prevent overwriting existing pending execution
        if (self.pendingExecution.targets.length > 0) {
            revert InvalidExecutionState("PENDING_EXISTS");
        }

        // Validate arrays have same length
        if (targets.length == 0) revert InvalidExecutionState("EMPTY_ARRAYS");
        if (targets.length != calldatas.length) revert InvalidExecutionState("ARRAY_MISMATCH");

        // Check if all targets are allowed
        // Special handling for address(this): only _setTimelockDelay() is allowed
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(this)) {
                // For self-calls, validate function selector
                if (!_isAllowedSelector(bytes4(calldatas[i]), allowedSelfCallSelectors)) {
                    revert InvalidExecutionState("INVALID_SELF_CALL");
                }
            } else if (!self.allowedTargets[targets[i]]) {
                revert InvalidExecutionState("NOTALLOWED");
            }
        }

        // Calculate timelock timestamp following OpenZeppelin pattern
        uint256 executeAfter = block.timestamp + self.timelockDelay;

        // Store pending execution
        self.pendingExecution = PendingExecution({ targets: targets, calldatas: calldatas, executeAfter: executeAfter });

        emit ExecutionSubmitted(targets, calldatas, executeAfter);
    }

    /**
     * @notice Check if a selector is in the allowed list
     * @param selector The function selector to check
     * @param allowedSelectors Array of allowed selectors
     * @return True if selector is allowed
     */
    function _isAllowedSelector(bytes4 selector, bytes4[] memory allowedSelectors) private pure returns (bool) {
        for (uint256 i = 0; i < allowedSelectors.length; i++) {
            if (selector == allowedSelectors[i]) return true;
        }
        return false;
    }

    /**
     * @notice Execute the pending external calls
     * @param self Storage reference to timelock state
     * @return success Whether all external calls succeeded
     * @return returnData Encoded array of return data from each external call
     */
    function acceptExecution(TimelockStorage storage self) external returns (bool success, bytes memory returnData) {
        // Get execution details and check if pending exists
        address[] memory targets = self.pendingExecution.targets;
        if (targets.length == 0) revert InvalidExecutionState("NOPENDING");

        // Validate timelock window (OpenZeppelin pattern)
        if (block.timestamp < self.pendingExecution.executeAfter) {
            revert InvalidExecutionState("TIMELOCKED");
        }
        uint256 expireAt = self.pendingExecution.executeAfter + EXECUTION_WINDOW;
        if (block.timestamp > expireAt) {
            revert InvalidExecutionState("EXPIRED");
        }

        // Re-validate allowlist: targets may have been removed after submission
        bytes[] memory calldatas = self.pendingExecution.calldatas;
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] != address(this) && !self.allowedTargets[targets[i]]) {
                revert InvalidExecutionState("NOTALLOWED");
            }
        }

        // Clear pending execution state
        delete self.pendingExecution;

        // Execute all calls in batch
        bytes[] memory returnDataArray = new bytes[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            (bool callSuccess, bytes memory callReturnData) = targets[i].call(calldatas[i]);
            if (!callSuccess) revert ExecutionFailed();
            returnDataArray[i] = callReturnData;
        }

        // Encode return data array for backward compatibility
        returnData = abi.encode(returnDataArray);
        success = true;

        emit ExecutionAccepted(targets, calldatas, returnDataArray);
    }

    /**
     * @notice Cancel the pending execution
     * @param self Storage reference to timelock state
     */
    function cancelExecution(TimelockStorage storage self) external {
        // Get targets and check if pending exists
        address[] memory targets = self.pendingExecution.targets;
        if (targets.length == 0) revert InvalidExecutionState("NOPENDING");

        // Clear pending execution state
        delete self.pendingExecution;

        emit ExecutionCancelled(targets);
    }

    /**
     * @notice Add or remove a target address from the whitelist
     * @param self Storage reference to timelock state
     * @param target The address to update in the whitelist
     * @param allowed Whether the target should be allowed
     */
    function setAllowedTarget(TimelockStorage storage self, address target, bool allowed) external {
        // Prevent whitelisting self
        if (target == address(this)) revert InvalidExecutionState("SELFWHITELIST");

        // Update allowlist
        self.allowedTargets[target] = allowed;

        // Auto-cancel pending execution if a target is removed
        if (!allowed && self.pendingExecution.targets.length > 0) {
            address[] memory targets = self.pendingExecution.targets;
            for (uint256 i = 0; i < targets.length; i++) {
                if (targets[i] == target) {
                    delete self.pendingExecution;
                    emit ExecutionCancelled(targets);
                    break;
                }
            }
        }

        emit TargetAllowlistUpdated(target, allowed);
    }

    /**
     * @notice Updates the timelock delay for governance executions
     * @param self Storage reference to timelock state
     * @param newDelay The new timelock delay in seconds (must be between MIN and MAX)
     */
    function setTimelockDelay(TimelockStorage storage self, uint256 newDelay) external {
        // Validate delay is within acceptable bounds
        if (newDelay < MIN_TIMELOCK_DELAY || newDelay > MAX_TIMELOCK_DELAY) {
            revert InvalidExecutionState("INVALID_DELAY");
        }

        uint256 oldDelay = self.timelockDelay;
        self.timelockDelay = newDelay;

        emit TimelockDelayUpdated(oldDelay, newDelay);
    }
}
