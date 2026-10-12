// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEthereumRewardPayer {
    struct RewardClaim {
        uint32 userId;
        bytes32 oldNullifierRoot;
        bytes32 newNullifierRoot;
        uint32 count;
        uint256 amount;
        address recipient;
    }

    event RewardPaid(
        uint32 indexed userId,
        bytes32 indexed oldNullifierRoot,
        bytes32 newNullifierRoot,
        uint32 count,
        uint256 amount,
        address indexed recipient
    );
    event RewardSkipped(uint32 indexed userId, bytes32 indexed oldNullifierRoot, uint8 reason);

    function configHash() external view returns (bytes32);
    function stateManager() external view returns (address);
    function ethereumChainId() external view returns (uint256);
    function rewardCallGasCap() external view returns (uint256);
    function rewardNullifierRoot(uint256 userId) external view returns (bytes32);
    function payRewards(RewardClaim[] calldata claims) external;
}
