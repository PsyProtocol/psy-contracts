// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExecutorWithTimelock {
    event NewPendingAdmin(address indexed newPendingAdmin);
    event NewAdmin(address indexed newAdmin);
    event NewDelay(uint256 delay);
    event QueuedAction(
        bytes32 actionHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 executionTime
    );
    event CancelledAction(
        bytes32 actionHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 executionTime
    );
    event ExecutedAction(
        bytes32 actionHash,
        address indexed target,
        uint256 value,
        string signature,
        bytes data,
        uint256 executionTime,
        bytes resultData
    );

    function GRACE_PERIOD() external view returns (uint256);
    function MINIMUM_DELAY() external view returns (uint256);
    function MAXIMUM_DELAY() external view returns (uint256);
    function getAdmin() external view returns (address);
    function getPendingAdmin() external view returns (address);
    function getDelay() external view returns (uint256);
    function isActionQueued(bytes32 actionHash) external view returns (bool);

    function queueTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 executionTime
    ) external returns (bytes32);

    function executeTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 executionTime
    ) external payable returns (bytes memory);

    function cancelTransaction(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 executionTime
    ) external returns (bytes32);
}
