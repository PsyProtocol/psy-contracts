// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BridgeOpening} from "./BridgeOpening.sol";

interface IEthereumRewardPayer {
    function configHash() external view returns (bytes32);
    function stateManager() external view returns (address);
    function ethereumChainId() external view returns (uint256);
    function payRewards(BridgeOpening.RewardLeaf[] calldata rewards) external;
}
