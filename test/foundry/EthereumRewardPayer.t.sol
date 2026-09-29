// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {EthereumRewardPayer} from "../../src/EthereumRewardPayer.sol";

// Adversarial token behaviors are confined to this test package.
contract RewardPayoutToken is ERC20 {
    enum Behavior { Exact, Fee, ExtraDebit, Rebase, FalseReturn, RevertTransfer, Reenter }

    Behavior public behavior;
    address public failingRecipient;
    address public callback;

    error TransferRejected();

    constructor() ERC20("Reward payout test", "RPT") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setBehavior(Behavior value, address recipient, address callback_) external {
        behavior = value;
        failingRecipient = recipient;
        callback = callback_;
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (failingRecipient != address(0) && failingRecipient != recipient) {
            return super.transfer(recipient, amount);
        }
        if (behavior == Behavior.FalseReturn) return false;
        if (behavior == Behavior.RevertTransfer) revert TransferRejected();
        if (behavior == Behavior.Reenter) {
            RewardPayoutCallback(callback).reenter();
        }
        if (behavior == Behavior.Fee) {
            _transfer(msg.sender, recipient, amount - 1);
            _transfer(msg.sender, address(0xFEE), 1);
            return true;
        }
        bool success = super.transfer(recipient, amount);
        if (behavior == Behavior.ExtraDebit) _transfer(msg.sender, address(0xFEE), 1);
        if (behavior == Behavior.Rebase) _mint(address(0xFEE), 1);
        return success;
    }
}

interface RewardPayoutCallback {
    function reenter() external;
}

contract EthereumRewardPayerTest is Test, RewardPayoutCallback {
    uint256 internal constant PRICE = 17;
    uint64 internal constant CUTOVER = 100;
    uint64 internal constant END = 200;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    RewardPayoutToken internal token;
    EthereumRewardPayer internal payer;

    function setUp() public {
        token = new RewardPayoutToken();
        payer = _deploy(PRICE);
        token.mint(address(payer), PRICE * 10);
    }

    function _config(address payerAddress, address tokenAddress, uint256 price, uint256 chainId)
        internal view returns (bytes memory)
    {
        return bytes.concat(
            abi.encode(uint32(1), uint64(42), uint32(524288), bytes32(uint256(1)), uint256(1)),
            abi.encode(uint8(7), chainId, address(0xB123), address(this), uint64(0),
                uint64(1), uint64(2), uint64(3), uint64(4)),
            abi.encode(uint8(7), payerAddress, tokenAddress, price, uint8(18), CUTOVER, END,
                uint32(1024), uint32(1024), uint32(1024))
        );
    }

    function _deploy(uint256 price) internal returns (EthereumRewardPayer) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        return new EthereumRewardPayer(_config(predicted, address(token), price, block.chainid));
    }

    function _rewards() internal pure returns (BridgeOpening.RewardLeaf[] memory rewards) {
        rewards = new BridgeOpening.RewardLeaf[](2);
        rewards[0] = BridgeOpening.RewardLeaf(CUTOVER, 1000, 2, 0, 3, ALICE);
        rewards[1] = BridgeOpening.RewardLeaf(CUTOVER, 1001, 3, 1, 8, BOB);
    }

    function _key(BridgeOpening.RewardLeaf memory reward) internal view returns (bytes32) {
        return keccak256(abi.encode(payer.rewardNullifierDomain(), reward.claimCheckpointId, reward.nullifierIndex));
    }

    function _assertUnpaid(BridgeOpening.RewardLeaf[] memory rewards) internal view {
        assertEq(token.balanceOf(address(payer)), PRICE * 10);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        for (uint256 i; i < rewards.length; ++i) assertFalse(payer.spentRewards(_key(rewards[i])));
    }

    function testPaysExactFixedPriceAndConsumesEachKey() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        payer.payRewards(rewards);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(token.balanceOf(address(payer)), PRICE * 8);
        assertTrue(payer.spentRewards(_key(rewards[0])));
        assertTrue(payer.spentRewards(_key(rewards[1])));
    }

    function testRepeatedRecipientReceivesEachDistinctReward() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].recipient = ALICE;
        payer.payRewards(rewards);
        assertEq(token.balanceOf(ALICE), PRICE * 2);
        assertEq(token.balanceOf(address(payer)), PRICE * 8);
    }

    function testChangedRecipientAndUserCannotReplayConsumedPosition() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        payer.payRewards(rewards);
        rewards[0].recipient = BOB;
        rewards[0].userId = 9999;
        vm.expectRevert(EthereumRewardPayer.RewardAlreadySpent.selector);
        payer.payRewards(rewards);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(token.balanceOf(address(payer)), PRICE * 8);
    }

    function testRejectsUnconfiguredCaller() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        vm.prank(ALICE);
        vm.expectRevert(EthereumRewardPayer.OnlyStateManager.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testRejectsOtherChainAfterDeployment() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        vm.chainId(block.chainid + 1);
        vm.expectRevert(EthereumRewardPayer.WrongChain.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testZeroPriceCannotDeploy() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory config = _config(predicted, address(token), 0, block.chainid);
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        new EthereumRewardPayer(config);
    }

    function testWrongPayerAddressCannotDeploy() public {
        bytes memory config = _config(ALICE, address(token), PRICE, block.chainid);
        vm.expectRevert(EthereumRewardPayer.InvalidPayerConfig.selector);
        new EthereumRewardPayer(config);
    }

    function testTokenWithoutCodeCannotDeploy() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory config = _config(predicted, ALICE, PRICE, block.chainid);
        vm.expectRevert(EthereumRewardPayer.InvalidPayerConfig.selector);
        new EthereumRewardPayer(config);
    }

    function testOtherChainCannotDeploy() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes memory config = _config(predicted, address(token), PRICE, block.chainid + 1);
        vm.expectRevert(EthereumRewardPayer.WrongChain.selector);
        new EthereumRewardPayer(config);
    }

    function testAggregatePriceOverflowRevertsBeforeConsumption() public {
        payer = _deploy(type(uint256).max);
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        payer.payRewards(rewards);
        assertFalse(payer.spentRewards(_key(rewards[0])));
        assertFalse(payer.spentRewards(_key(rewards[1])));
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testUnderfundedBatchCannotConsumeAnyKey() public {
        payer = _deploy(PRICE);
        token.mint(address(payer), PRICE * 2 - 1);
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        vm.expectRevert(EthereumRewardPayer.InsufficientRewardReserve.selector);
        payer.payRewards(rewards);
        assertEq(token.balanceOf(address(payer)), PRICE * 2 - 1);
        assertFalse(payer.spentRewards(_key(rewards[0])));
        assertFalse(payer.spentRewards(_key(rewards[1])));
        assertEq(token.balanceOf(ALICE), 0);
        token.mint(address(payer), 1);
        payer.payRewards(rewards);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(token.balanceOf(address(payer)), 0);
    }

    function testDuplicatePositionRejectsWholeBatch() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1] = rewards[0];
        rewards[1].recipient = BOB;
        vm.expectRevert(EthereumRewardPayer.InvalidRewardOrdering.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testDescendingCheckpointRejectsWholeBatch() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[0].claimCheckpointId = CUTOVER + 1;
        vm.expectRevert(EthereumRewardPayer.InvalidRewardOrdering.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testRejectsClaimBeforeCutover() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[0].claimCheckpointId = CUTOVER - 1;
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testEndCheckpointIsExclusive() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].claimCheckpointId = END;
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
        rewards[1].claimCheckpointId = END - 1;
        payer.payRewards(rewards);
        assertEq(token.balanceOf(BOB), PRICE);
    }

    function testRejectsNonGutaPosition() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].pathIndex = 2;
        rewards[1].nullifierIndex = 9;
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testRejectsNullifierAlias() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].nullifierIndex = 7;
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testFuzzRejectsOutOfRangeHeight(uint8 height) public {
        vm.assume(height < 2 || height > 21);
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].height = height;
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testMaximumCanonicalGutaPositionAccepts() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].height = 21;
        rewards[1].pathIndex = (uint32(1) << 19) - 1;
        rewards[1].nullifierIndex = (uint32(1) << 21) - 1 + rewards[1].pathIndex;
        payer.payRewards(rewards);
        assertEq(token.balanceOf(BOB), PRICE);
    }

    function testRejectsZeroRecipient() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].recipient = address(0);
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testRejectsPayerAsRecipient() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        rewards[1].recipient = address(payer);
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testFeeTransferRollsBackEarlierPaymentAndAllKeys() public {
        _rejectTransfer(RewardPayoutToken.Behavior.Fee,
            abi.encodeWithSelector(EthereumRewardPayer.UnsupportedTokenTransfer.selector));
    }

    function testExtraDebitRollsBackEarlierPaymentAndAllKeys() public {
        _rejectTransfer(RewardPayoutToken.Behavior.ExtraDebit,
            abi.encodeWithSelector(EthereumRewardPayer.UnsupportedTokenTransfer.selector));
    }

    function testRebaseRollsBackEarlierPaymentAndAllKeys() public {
        _rejectTransfer(RewardPayoutToken.Behavior.Rebase,
            abi.encodeWithSelector(EthereumRewardPayer.UnsupportedTokenTransfer.selector));
    }

    function testFalseTransferRollsBackEarlierPaymentAndAllKeys() public {
        _rejectTransfer(RewardPayoutToken.Behavior.FalseReturn,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
    }

    function testRevertedTransferRollsBackEarlierPaymentAndAllKeys() public {
        _rejectTransfer(RewardPayoutToken.Behavior.RevertTransfer,
            abi.encodeWithSelector(RewardPayoutToken.TransferRejected.selector));
    }

    function testAuthorizedReentryRollsBackEarlierPaymentAndAllKeys() public {
        _rejectTransfer(RewardPayoutToken.Behavior.Reenter,
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    function _rejectTransfer(RewardPayoutToken.Behavior behavior, bytes memory reason) internal {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        token.setBehavior(behavior, BOB, address(this));
        vm.expectRevert(reason);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
        assertEq(token.totalSupply(), PRICE * 10);
        token.setBehavior(RewardPayoutToken.Behavior.Exact, address(0), address(0));
        payer.payRewards(rewards);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
    }

    function testConsumedLaterKeyRollsBackEarlierFreshKey() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        BridgeOpening.RewardLeaf[] memory one = new BridgeOpening.RewardLeaf[](1);
        one[0] = rewards[1];
        payer.payRewards(one);
        vm.expectRevert(EthereumRewardPayer.RewardAlreadySpent.selector);
        payer.payRewards(rewards);
        assertFalse(payer.spentRewards(_key(rewards[0])));
        assertTrue(payer.spentRewards(_key(rewards[1])));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(token.balanceOf(address(payer)), PRICE * 9);
    }

    function testDescendingNullifierRejectsWholeBatch() public {
        BridgeOpening.RewardLeaf[] memory rewards = _rewards();
        BridgeOpening.RewardLeaf memory first = rewards[0];
        rewards[0] = rewards[1];
        rewards[1] = first;
        vm.expectRevert(EthereumRewardPayer.InvalidRewardOrdering.selector);
        payer.payRewards(rewards);
        _assertUnpaid(rewards);
    }

    function testRejectsRewardCountAboveCommittedMaximum() public {
        BridgeOpening.RewardLeaf[] memory rewards = new BridgeOpening.RewardLeaf[](1025);
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(rewards);
        assertEq(token.balanceOf(address(payer)), PRICE * 10);
    }

    function testCanonicalDomainConsumesExpectedStableKey() public {
        bytes32 domain = keccak256(abi.encode(
            keccak256("PsyBridge/TwoArtifact/1/Reward"), uint256(1), uint64(42), uint32(524288),
            block.chainid, uint8(7), address(payer), address(token)
        ));
        payer.payRewards(_rewards());
        assertTrue(payer.spentRewards(keccak256(abi.encode(domain, uint64(CUTOVER), uint32(3)))));
        assertFalse(payer.spentRewards(keccak256(abi.encode(domain, uint64(CUTOVER + 1), uint32(3)))));
    }

    function testEmptyBatchDoesNotSpendReserve() public {
        payer.payRewards(new BridgeOpening.RewardLeaf[](0));
        assertEq(token.balanceOf(address(payer)), PRICE * 10);
    }

    function reenter() external override {
        require(msg.sender == address(token));
        payer.payRewards(_rewards());
    }
}
