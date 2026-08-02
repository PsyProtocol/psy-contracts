// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IExecutorWithTimelock} from "./IExecutorWithTimelock.sol";

/// @notice Aave/Paraspace-style single-admin timelock executor for Psy operations.
contract ExecutorWithTimelock is IExecutorWithTimelock {
    uint256 public immutable override GRACE_PERIOD;
    uint256 public immutable override MINIMUM_DELAY;
    uint256 public immutable override MAXIMUM_DELAY;

    address private _admin;
    address private _pendingAdmin;
    uint256 private _delay;
    mapping(bytes32 => bool) private _queuedTransactions;

    constructor(address admin, uint256 delay, uint256 gracePeriod, uint256 minimumDelay, uint256 maximumDelay) {
        require(admin != address(0), "ADMIN_ZERO");
        require(delay >= minimumDelay, "DELAY_SHORTER_THAN_MINIMUM");
        require(delay <= maximumDelay, "DELAY_LONGER_THAN_MAXIMUM");
        require(gracePeriod != 0, "GRACE_PERIOD_ZERO");
        require(minimumDelay <= maximumDelay, "INVALID_DELAY_BOUNDS");
        _admin = admin;
        _delay = delay;
        GRACE_PERIOD = gracePeriod;
        MINIMUM_DELAY = minimumDelay;
        MAXIMUM_DELAY = maximumDelay;
        emit NewDelay(delay);
        emit NewAdmin(admin);
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, "ONLY_BY_ADMIN");
        _;
    }

    modifier onlyTimelock() {
        require(msg.sender == address(this), "ONLY_BY_THIS_TIMELOCK");
        _;
    }

    modifier onlyPendingAdmin() {
        require(msg.sender == _pendingAdmin, "ONLY_BY_PENDING_ADMIN");
        _;
    }

    receive() external payable {}

    function getAdmin() external view override returns (address) {
        return _admin;
    }

    function getPendingAdmin() external view override returns (address) {
        return _pendingAdmin;
    }

    function getDelay() external view override returns (uint256) {
        return _delay;
    }

    function isActionQueued(bytes32 actionHash) external view override returns (bool) {
        return _queuedTransactions[actionHash];
    }

    function setDelay(uint256 delay) external onlyTimelock {
        require(delay >= MINIMUM_DELAY, "DELAY_SHORTER_THAN_MINIMUM");
        require(delay <= MAXIMUM_DELAY, "DELAY_LONGER_THAN_MAXIMUM");
        _delay = delay;
        emit NewDelay(delay);
    }

    function setPendingAdmin(address newPendingAdmin) external onlyTimelock {
        _pendingAdmin = newPendingAdmin;
        emit NewPendingAdmin(newPendingAdmin);
    }

    function acceptAdmin() external onlyPendingAdmin {
        _admin = msg.sender;
        _pendingAdmin = address(0);
        emit NewAdmin(msg.sender);
    }

    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 executionTime,
        bool withDelegatecall
    ) public override onlyAdmin returns (bytes32) {
        require(executionTime >= block.timestamp + _delay, "EXECUTION_TIME_UNDERESTIMATED");
        bytes32 actionHash = keccak256(abi.encode(target, value, signature, data, executionTime, withDelegatecall));
        _queuedTransactions[actionHash] = true;
        emit QueuedAction(actionHash, target, value, signature, data, executionTime, withDelegatecall);
        return actionHash;
    }

    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 executionTime,
        bool withDelegatecall
    ) public override onlyAdmin returns (bytes32) {
        bytes32 actionHash = keccak256(abi.encode(target, value, signature, data, executionTime, withDelegatecall));
        _queuedTransactions[actionHash] = false;
        emit CancelledAction(actionHash, target, value, signature, data, executionTime, withDelegatecall);
        return actionHash;
    }

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 executionTime,
        bool withDelegatecall
    ) public payable override onlyAdmin returns (bytes memory) {
        bytes32 actionHash = keccak256(abi.encode(target, value, signature, data, executionTime, withDelegatecall));
        require(_queuedTransactions[actionHash], "ACTION_NOT_QUEUED");
        require(block.timestamp >= executionTime, "TIMELOCK_NOT_FINISHED");
        require(block.timestamp <= executionTime + GRACE_PERIOD, "GRACE_PERIOD_FINISHED");
        _queuedTransactions[actionHash] = false;

        bytes memory callData = bytes(signature).length == 0
            ? data
            : abi.encodePacked(bytes4(keccak256(bytes(signature))), data);

        bool success;
        bytes memory resultData;
        if (withDelegatecall) {
            require(msg.value >= value, "NOT_ENOUGH_MSG_VALUE");
            (success, resultData) = target.delegatecall(callData);
        } else {
            (success, resultData) = target.call{value: value}(callData);
        }
        require(success, "FAILED_ACTION_EXECUTION");

        emit ExecutedAction(actionHash, target, value, signature, data, executionTime, withDelegatecall, resultData);
        return resultData;
    }
}
