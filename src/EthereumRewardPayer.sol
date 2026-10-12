// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BridgeOpening} from "./BridgeOpening.sol";
import {IEthereumRewardPayer} from "./IEthereumRewardPayer.sol";

contract EthereumRewardPayer is IEthereumRewardPayer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    uint256 internal constant MAX_CLAIMS = 32;
    // solc 0.8.24+commit.e11b9ed9, via-IR, optimizer 200, Paris.
    // Static ceilings of the compiled parent: attempted row 2295, skip tail 1920, finish 5041.
    uint256 internal constant PARENT_ROW_GAS = 4000;
    uint256 internal constant SKIP_ROW_GAS = 3000;
    uint256 internal constant FINISH_GAS = 8000;

    bytes32 public constant EMPTY_REWARD_NULLIFIER_ROOT =
        0x529e7df136402acdfe6445425d3d3f067df8eeacb72c4c10796146105b07bbd6;
    uint8 public constant REASON_STALE_ROOT = 1;
    uint8 public constant REASON_INVALID_CLAIM = 2;
    uint8 public constant REASON_INSUFFICIENT_RESERVE = 3;
    uint8 public constant REASON_TRANSFER_FAILED = 4;
    uint8 public constant REASON_INSUFFICIENT_GAS = 5;

    bytes32 public immutable override configHash;
    address public immutable override stateManager;
    uint256 public immutable override ethereumChainId;
    uint256 public immutable override rewardCallGasCap;
    IERC20 public immutable rewardToken;
    mapping(uint256 userId => bytes32 root) public override rewardNullifierRoot;

    error InvalidPayerConfig();
    error OnlyStateManager();
    error WrongChain();
    error InvalidReward();
    error InvalidGasCap();
    error OnlySelf();
    error RewardStaleRoot();
    error RewardInvalid();
    error RewardReserveShort();
    error UnsupportedTokenTransfer();

    constructor(bytes memory canonicalConfig, uint256 rewardCallGasCap_) {
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(canonicalConfig);
        BridgeOpening.ChainConfig memory chain =
            config.chains[BridgeOpening.chainOrdinal(config, config.ethereumIndex)];
        if (config.rewardPayer != address(this) || config.rewardToken.code.length == 0) revert InvalidPayerConfig();
        if (chain.chainId != block.chainid) revert WrongChain();
        uint256 tail = PARENT_ROW_GAS + FINISH_GAS + MAX_CLAIMS * SKIP_ROW_GAS + 1;
        uint256 maxCap = (type(uint256).max - tail) / 64 * 63;
        if (rewardCallGasCap_ == 0 || rewardCallGasCap_ > maxCap) revert InvalidGasCap();
        configHash = config.configHash;
        stateManager = chain.stateManager;
        ethereumChainId = chain.chainId;
        rewardToken = IERC20(config.rewardToken);
        rewardCallGasCap = rewardCallGasCap_;
    }

    function payRewards(RewardClaim[] calldata claims) external override nonReentrant {
        if (msg.sender != stateManager) revert OnlyStateManager();
        if (block.chainid != ethereumChainId) revert WrongChain();
        uint256 count = claims.length;
        if (count > MAX_CLAIMS) revert InvalidReward();

        uint256 cap = rewardCallGasCap;
        bytes4 selector = this.payReward.selector;
        bytes4 stale = RewardStaleRoot.selector;
        bytes4 bad = RewardInvalid.selector;
        bytes4 reserve = RewardReserveShort.selector;
        bytes32 skipped = RewardSkipped.selector;
        assembly ("memory-safe") {
            function emitSkip(row, reason, topic, data) {
                mstore(data, reason)
                log3(
                    data,
                    32,
                    topic,
                    and(calldataload(row), 0xffffffff),
                    calldataload(add(row, 32))
                )
            }

            let n := count
            let base := add(4, calldataload(4))
            let buf := mload(0x40)
            mstore(buf, selector)
            mstore(add(buf, 192), 0)
            mstore(add(buf, 224), 0)
            mstore(0x40, add(buf, 256))
            let ret := add(buf, 224)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let row := add(add(base, 32), mul(i, 192))
                calldatacopy(add(buf, 4), row, 192)
                let gasNow := gas()
                let remaining := sub(n, i)
                let need := add(PARENT_ROW_GAS, cap)
                need := add(need, add(div(cap, 63), 1))
                need := add(need, add(mul(remaining, SKIP_ROW_GAS), FINISH_GAS))
                if lt(gasNow, need) {
                    for {} lt(i, n) { i := add(i, 1) } {
                        emitSkip(add(add(base, 32), mul(i, 192)), REASON_INSUFFICIENT_GAS, skipped, ret)
                    }
                }
                if iszero(lt(gasNow, need)) {
                    if iszero(call(cap, address(), 0, buf, 196, 0, 0)) {
                        mstore(ret, 0)
                        let size := returndatasize()
                        if iszero(lt(size, 4)) { returndatacopy(ret, 0, 4) }
                        let sel := mload(ret)
                        let reason := REASON_TRANSFER_FAILED
                        if eq(sel, stale) { reason := REASON_STALE_ROOT }
                        if eq(sel, bad) { reason := REASON_INVALID_CLAIM }
                        if eq(sel, reserve) { reason := REASON_INSUFFICIENT_RESERVE }
                        emitSkip(row, reason, skipped, ret)
                    }
                }
            }
        }
    }

    function payReward(RewardClaim calldata claim) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (
            claim.amount == 0 || claim.recipient == address(0) || claim.recipient == address(this)
                || !_canonical(claim.oldNullifierRoot) || !_canonical(claim.newNullifierRoot)
        ) revert RewardInvalid();

        bytes32 stored = rewardNullifierRoot[claim.userId];
        bytes32 expected = stored == bytes32(0) ? EMPTY_REWARD_NULLIFIER_ROOT : stored;
        if (claim.oldNullifierRoot != expected) revert RewardStaleRoot();

        uint256 amount = claim.amount;
        uint256 reserve = rewardToken.balanceOf(address(this));
        if (reserve < amount) revert RewardReserveShort();
        uint256 supply = rewardToken.totalSupply();
        uint256 recipientBefore = rewardToken.balanceOf(claim.recipient);
        rewardToken.safeTransfer(claim.recipient, amount);
        uint256 recipientAfter = rewardToken.balanceOf(claim.recipient);
        if (
            rewardToken.balanceOf(address(this)) != reserve - amount || recipientAfter != recipientBefore + amount
                || rewardToken.totalSupply() != supply
        ) revert UnsupportedTokenTransfer();

        rewardNullifierRoot[claim.userId] = claim.newNullifierRoot;
        emit RewardPaid(
            claim.userId, claim.oldNullifierRoot, claim.newNullifierRoot, claim.count, amount, claim.recipient
        );
    }

    function _canonical(bytes32 root) private pure returns (bool ok) {
        uint256 value = uint256(root);
        unchecked {
            for (uint256 shift = 192;;) {
                if ((value >> shift) & type(uint64).max >= GOLDILOCKS_PRIME) return false;
                if (shift == 0) return true;
                shift -= 64;
            }
        }
    }
}
