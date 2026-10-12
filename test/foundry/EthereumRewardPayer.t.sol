// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {EthereumRewardPayer} from "../../src/EthereumRewardPayer.sol";
import {IEthereumRewardPayer} from "../../src/IEthereumRewardPayer.sol";

// Adversarial token behaviors are confined to this test package.
contract RewardPayoutToken is ERC20 {
    enum Behavior { Exact, Fee, ExtraDebit, Rebase, FalseReturn, RevertTransfer, Reenter, BurnGas }

    Behavior public behavior;
    address public failingRecipient;
    address public callback;
    uint256 public burn;

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

    function setBurn(uint256 iterations) external {
        burn = iterations;
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
        if (behavior == Behavior.BurnGas) {
            uint256 sink;
            for (uint256 i; i < burn; ++i) sink = uint256(keccak256(abi.encode(sink, i)));
            sink;
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
    uint256 internal constant GAS_CAP = 500_000;
    bytes32 internal constant EMPTY =
        0x529e7df136402acdfe6445425d3d3f067df8eeacb72c4c10796146105b07bbd6;
    uint256 internal constant PRIME = 18446744069414584321;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    RewardPayoutToken internal token;
    EthereumRewardPayer internal payer;

    function setUp() public {
        token = new RewardPayoutToken();
        payer = _deploy(GAS_CAP);
        token.mint(address(payer), PRICE * 10);
    }

    function _config(address payerAddress, address tokenAddress, uint256 chainId) internal view returns (bytes memory) {
        return bytes.concat(
            abi.encode(uint32(1), uint64(42), uint32(524288), bytes32(uint256(1)), uint256(1)),
            abi.encode(
                uint8(7), chainId, address(0xB123), address(this), uint64(0), uint64(1), uint64(2), uint64(3), uint64(4)
            ),
            abi.encode(uint8(7), payerAddress, tokenAddress, uint256(1), uint8(18), uint32(32), uint32(32))
        );
    }

    function _deploy(uint256 gasCap) internal returns (EthereumRewardPayer) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        return new EthereumRewardPayer(_config(predicted, address(token), block.chainid), gasCap);
    }

    function _pack(uint256 limb0, uint256 limb1, uint256 limb2, uint256 limb3) internal pure returns (bytes32) {
        return bytes32((limb0 << 192) | (limb1 << 128) | (limb2 << 64) | limb3);
    }

    function _claim(uint32 userId, bytes32 oldRoot, bytes32 newRoot, uint256 amount, address recipient)
        internal
        pure
        returns (IEthereumRewardPayer.RewardClaim memory)
    {
        return IEthereumRewardPayer.RewardClaim(userId, oldRoot, newRoot, 1, amount, recipient);
    }

    function _claims() internal pure returns (IEthereumRewardPayer.RewardClaim[] memory claims) {
        claims = new IEthereumRewardPayer.RewardClaim[](2);
        claims[0] = _claim(1000, EMPTY, _pack(1, 0, 0, 0), PRICE, ALICE);
        claims[1] = _claim(1001, EMPTY, _pack(2, 0, 0, 0), PRICE, BOB);
    }

    function _assertUntouched(IEthereumRewardPayer.RewardClaim[] memory claims) internal view {
        assertEq(token.balanceOf(address(payer)), PRICE * 10);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), PRICE * 10);
        for (uint256 i; i < claims.length; ++i) assertEq(payer.rewardNullifierRoot(claims[i].userId), bytes32(0));
    }

    function testPaysLineageAndAdvancesLiveRoot() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        vm.expectEmit(true, true, true, true);
        emit IEthereumRewardPayer.RewardPaid(1000, EMPTY, claims[0].newNullifierRoot, 1, PRICE, ALICE);
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(token.balanceOf(address(payer)), PRICE * 8);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), claims[1].newNullifierRoot);
    }

    function testSameUserSecondRowReadsLiveRoot() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        claims[1].userId = claims[0].userId;
        claims[1].recipient = ALICE;
        claims[1].oldNullifierRoot = claims[0].newNullifierRoot;
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE * 2);
        assertEq(payer.rewardNullifierRoot(claims[0].userId), claims[1].newNullifierRoot);
    }

    function testRepeatedPaymentRequiresSuccessorRoot() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        payer.payRewards(claims);
        claims[0].oldNullifierRoot = claims[0].newNullifierRoot;
        claims[0].newNullifierRoot = _pack(3, 0, 0, 0);
        claims = _one(claims[0]);
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE * 2);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
    }

    function testStaleRootSkipsWithoutChangingLineage() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        payer.payRewards(_one(claims[0]));
        vm.expectEmit(true, true, false, true);
        emit IEthereumRewardPayer.RewardSkipped(1000, EMPTY, payer.REASON_STALE_ROOT());
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), claims[1].newNullifierRoot);
    }

    function testInvalidClaimSkipsAndPreservesEarlierRoot() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        claims[1].amount = 0;
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), bytes32(0));

        claims[1].amount = PRICE;
        claims[1].recipient = address(0);
        payer.payRewards(_one(claims[1]));
        claims[1].recipient = address(payer);
        payer.payRewards(_one(claims[1]));
        claims[1].recipient = BOB;
        claims[1].oldNullifierRoot = _pack(PRIME, 0, 0, 0);
        payer.payRewards(_one(claims[1]));
        claims[1].oldNullifierRoot = EMPTY;
        claims[1].newNullifierRoot = _pack(0, 0, 0, PRIME);
        payer.payRewards(_one(claims[1]));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(payer.rewardNullifierRoot(1001), bytes32(0));
    }

    function testReserveShortSkipsOnlyThatRow() public {
        token = new RewardPayoutToken();
        payer = _deploy(GAS_CAP);
        token.mint(address(payer), PRICE);
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(payer)), 0);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), bytes32(0));
        token.mint(address(payer), PRICE);
        payer.payRewards(_one(claims[1]));
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(payer.rewardNullifierRoot(1001), claims[1].newNullifierRoot);
    }

    function testReceiptMismatchSkipsAndPreservesEarlierPayment() public {
        _skipTransfer(RewardPayoutToken.Behavior.Fee);
        _skipTransfer(RewardPayoutToken.Behavior.ExtraDebit);
        _skipTransfer(RewardPayoutToken.Behavior.Rebase);
        _skipTransfer(RewardPayoutToken.Behavior.FalseReturn);
        _skipTransfer(RewardPayoutToken.Behavior.RevertTransfer);
    }

    function testAuthorityAndChainRejectBeforePayment() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        vm.prank(ALICE);
        vm.expectRevert(EthereumRewardPayer.OnlyStateManager.selector);
        payer.payRewards(claims);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(EthereumRewardPayer.WrongChain.selector);
        payer.payRewards(claims);
        vm.chainId(block.chainid - 1);
        _assertUntouched(claims);
    }

    function testReentrancySkipsOnlyTheCallingRow() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        token.setBehavior(RewardPayoutToken.Behavior.Reenter, BOB, address(this));
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), bytes32(0));
        token.setBehavior(RewardPayoutToken.Behavior.Exact, address(0), address(0));
        payer.payRewards(_one(claims[1]));
        assertEq(token.balanceOf(BOB), PRICE);
    }

    function testGasBurnBecomesTransferFailedWithoutRootWrite() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        token.setBehavior(RewardPayoutToken.Behavior.BurnGas, BOB, address(0));
        token.setBurn(20_000);
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), bytes32(0));
        token.setBehavior(RewardPayoutToken.Behavior.Exact, address(0), address(0));
        payer.payRewards(_one(claims[1]));
        assertEq(token.balanceOf(BOB), PRICE);
    }

    function testCapOneStarvesRowCallsIntoTransferFailure() public {
        EthereumRewardPayer low = _deploy(1);
        token.mint(address(low), PRICE * 2);
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        // A cap of 1 clears the parent reserve gate but starves every child
        // call out of gas, so each row surfaces as a transfer failure; the
        // parent gate needs explicit bounded call gas and is covered below.
        vm.expectEmit(true, true, false, true);
        emit IEthereumRewardPayer.RewardSkipped(1000, EMPTY, low.REASON_TRANSFER_FAILED());
        vm.expectEmit(true, true, false, true);
        emit IEthereumRewardPayer.RewardSkipped(1001, EMPTY, low.REASON_TRANSFER_FAILED());
        low.payRewards(claims);
        assertEq(token.balanceOf(address(low)), PRICE * 2);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(low.rewardNullifierRoot(1000), bytes32(0));
        assertEq(low.rewardNullifierRoot(1001), bytes32(0));
    }

    function testInsufficientParentGasSkipsRemainingRowsAndPreservesPaidTail() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        payer.payRewards(claims);
        // Bounded gas below the parent reserve need (4000 + cap + cap/63 + 1 +
        // remaining * 3000 + 8000 ~= 526k here) but far above the skip tail,
        // so both rows are skipped by the parent gate itself with reason 5.
        vm.expectEmit(true, true, false, true);
        emit IEthereumRewardPayer.RewardSkipped(1000, EMPTY, payer.REASON_INSUFFICIENT_GAS());
        vm.expectEmit(true, true, false, true);
        emit IEthereumRewardPayer.RewardSkipped(1001, EMPTY, payer.REASON_INSUFFICIENT_GAS());
        payer.payRewards{gas: 100_000}(claims);
        assertEq(token.balanceOf(address(payer)), PRICE * 8);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), PRICE);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), claims[1].newNullifierRoot);
    }

    function testDeploymentRejectsBadIdentityAndGasCap() public {
        vm.expectRevert(EthereumRewardPayer.InvalidPayerConfig.selector);
        new EthereumRewardPayer(_config(ALICE, address(token), block.chainid), GAS_CAP);
        // A reverted CREATE still burns the deployer nonce, so the predicted
        // address is recomputed before every subsequent attempt.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(EthereumRewardPayer.InvalidPayerConfig.selector);
        new EthereumRewardPayer(_config(predicted, ALICE, block.chainid), GAS_CAP);
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(EthereumRewardPayer.WrongChain.selector);
        new EthereumRewardPayer(_config(predicted, address(token), block.chainid + 1), GAS_CAP);
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(EthereumRewardPayer.InvalidGasCap.selector);
        new EthereumRewardPayer(_config(predicted, address(token), block.chainid), 0);
        // The WrongChain attempt above read the same source config
        // successfully, so trailing bytes isolate the typed decoder only.
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        new EthereumRewardPayer(bytes.concat(_config(predicted, address(token), block.chainid), bytes32(0)), GAS_CAP);
    }

    function testRejectsMoreThanThirtyTwoClaims() public {
        IEthereumRewardPayer.RewardClaim[] memory claims = new IEthereumRewardPayer.RewardClaim[](33);
        vm.expectRevert(EthereumRewardPayer.InvalidReward.selector);
        payer.payRewards(claims);
        assertEq(token.balanceOf(address(payer)), PRICE * 10);
    }

    function testEmptyBatchDoesNotSpendReserve() public {
        payer.payRewards(new IEthereumRewardPayer.RewardClaim[](0));
        assertEq(token.balanceOf(address(payer)), PRICE * 10);
    }

    function testDirectPayRewardIsSelfOnly() public {
        vm.expectRevert(EthereumRewardPayer.OnlySelf.selector);
        payer.payReward(_claims()[0]);
        _assertUntouched(_claims());
    }

    function _one(IEthereumRewardPayer.RewardClaim memory claim)
        internal
        pure
        returns (IEthereumRewardPayer.RewardClaim[] memory claims)
    {
        claims = new IEthereumRewardPayer.RewardClaim[](1);
        claims[0] = claim;
    }

    function _skipTransfer(RewardPayoutToken.Behavior behavior) internal {
        token = new RewardPayoutToken();
        payer = _deploy(GAS_CAP);
        token.mint(address(payer), PRICE * 2);
        IEthereumRewardPayer.RewardClaim[] memory claims = _claims();
        token.setBehavior(behavior, BOB, address(this));
        payer.payRewards(claims);
        assertEq(token.balanceOf(ALICE), PRICE);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(payer)), PRICE);
        // The Rebase mint happens inside the reverted child frame, so it rolls
        // back atomically: supply is the pre-row baseline and no new call
        // frame's effect survives.
        assertEq(token.totalSupply(), PRICE * 2);
        assertEq(payer.rewardNullifierRoot(1000), claims[0].newNullifierRoot);
        assertEq(payer.rewardNullifierRoot(1001), bytes32(0));
    }

    function reenter() external override {
        require(msg.sender == address(token));
        payer.payRewards(_claims());
    }
}
