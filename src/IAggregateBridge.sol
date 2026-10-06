// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BridgeOpening} from "./BridgeOpening.sol";

interface IAggregateBridge {
    function configHash() external view returns (bytes32);
    function depositRoot() external view returns (bytes32);
    function provedDepositCount() external view returns (uint256);
    function applyDepositAggregate(bytes calldata completeOpening) external;
    function publishClaimHeader(bytes calldata headerBytes) external;
}
