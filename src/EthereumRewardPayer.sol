// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BridgeOpening} from "./BridgeOpening.sol";
import {IEthereumRewardPayer} from "./IEthereumRewardPayer.sol";

contract EthereumRewardPayer is IEthereumRewardPayer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public immutable override configHash;
    address public immutable override stateManager;
    uint256 public immutable override ethereumChainId;
    IERC20 public immutable rewardToken;
    uint256 public immutable REWARD_PER_CLAIM;
    bytes32 public immutable rewardNullifierDomain;
    uint64 public immutable rewardCutover;
    uint64 public immutable rewardEndExclusive;
    uint32 public immutable maxRewards;
    mapping(bytes32 => bool) public spentRewards;

    error InvalidPayerConfig();
    error OnlyStateManager();
    error WrongChain();
    error InvalidReward();
    error InvalidRewardOrdering();
    error RewardAlreadySpent();
    error InsufficientRewardReserve();
    error UnsupportedTokenTransfer();

    constructor(bytes memory canonicalConfig) {
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(canonicalConfig);
        BridgeOpening.ChainConfig memory chain = config.chains[BridgeOpening.chainOrdinal(config, config.ethereumIndex)];
        if (config.rewardPayer != address(this) || config.rewardToken.code.length == 0) revert InvalidPayerConfig();
        if (chain.chainId != block.chainid) revert WrongChain();
        configHash = config.configHash;
        stateManager = chain.stateManager;
        ethereumChainId = chain.chainId;
        rewardToken = IERC20(config.rewardToken);
        REWARD_PER_CLAIM = config.rewardPerClaim;
        rewardCutover = config.rewardCutover;
        rewardEndExclusive = config.rewardEndExclusive;
        maxRewards = config.maxRewards;
        rewardNullifierDomain = keccak256(abi.encode(
            keccak256("PsyBridge/TwoArtifact/1/Reward"), uint256(1), config.networkMagic,
            uint32(524288), chain.chainId, config.ethereumIndex, address(this), config.rewardToken
        ));
    }

    function payRewards(BridgeOpening.RewardLeaf[] calldata rewards) external override nonReentrant {
        if (msg.sender != stateManager) revert OnlyStateManager();
        if (block.chainid != ethereumChainId) revert WrongChain();
        if (rewards.length > maxRewards) revert InvalidReward();
        uint256 total = rewards.length * REWARD_PER_CLAIM;
        uint256 reserve = rewardToken.balanceOf(address(this));
        if (reserve < total) revert InsufficientRewardReserve();

        for (uint256 i; i < rewards.length; ++i) {
            BridgeOpening.RewardLeaf calldata reward = rewards[i];
            if (
                reward.claimCheckpointId < rewardCutover || reward.claimCheckpointId >= rewardEndExclusive
                    || reward.height < 2 || reward.height > 21
                    || reward.recipient == address(0) || reward.recipient == address(this)
            ) revert InvalidReward();
            if (
                reward.pathIndex >= uint32(1) << (reward.height - 2)
                    || reward.nullifierIndex != (uint32(1) << reward.height) - 1 + reward.pathIndex
            ) revert InvalidReward();
            if (i != 0) {
                BridgeOpening.RewardLeaf calldata previous = rewards[i - 1];
                if (
                    previous.claimCheckpointId > reward.claimCheckpointId
                        || (previous.claimCheckpointId == reward.claimCheckpointId
                            && previous.nullifierIndex >= reward.nullifierIndex)
                ) revert InvalidRewardOrdering();
            }
            bytes32 key = keccak256(abi.encode(rewardNullifierDomain, reward.claimCheckpointId, reward.nullifierIndex));
            if (spentRewards[key]) revert RewardAlreadySpent();
            spentRewards[key] = true;
        }

        uint256 supply = rewardToken.totalSupply();
        for (uint256 i; i < rewards.length; ++i) {
            address recipient = rewards[i].recipient;
            uint256 recipientBalance = rewardToken.balanceOf(recipient);
            rewardToken.safeTransfer(recipient, REWARD_PER_CLAIM);
            reserve -= REWARD_PER_CLAIM;
            uint256 receivedBalance = rewardToken.balanceOf(recipient);
            if (
                rewardToken.balanceOf(address(this)) != reserve || receivedBalance < recipientBalance
                    || receivedBalance - recipientBalance != REWARD_PER_CLAIM || rewardToken.totalSupply() != supply
            ) revert UnsupportedTokenTransfer();
        }
    }
}
