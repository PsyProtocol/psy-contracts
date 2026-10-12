// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {IEthereumRewardPayer} from "../../src/IEthereumRewardPayer.sol";

contract BridgeOpeningHarness {
    function readConfig(bytes calldata body) external pure returns (BridgeOpening.NetworkConfig memory) {
        return BridgeOpening.readConfig(body);
    }
    function readBridgeOpening(bytes calldata config, bytes calldata opening) external pure returns (BridgeOpening.BridgeOpeningBody memory) {
        return BridgeOpening.readBridgeOpening(opening, BridgeOpening.readConfig(config));
    }
}

contract BridgeOpeningTest is Test {
    uint256 private constant P = 18446744069414584321;
    BridgeOpeningHarness private harness = new BridgeOpeningHarness();

    function _words(uint256 value) private pure returns (bytes memory) {
        return abi.encode(value);
    }
    function _root(uint256 limb0, uint256 limb1, uint256 limb2, uint256 limb3) private pure returns (bytes memory) {
        return abi.encode(limb0, limb1, limb2, limb3);
    }
    function _packed(uint256 limb0, uint256 limb1, uint256 limb2, uint256 limb3) private pure returns (bytes32) {
        return bytes32((limb0 << 192) | (limb1 << 128) | (limb2 << 64) | limb3);
    }
    function _chain(uint256 index, uint256 chainId) private pure returns (bytes memory) {
        return bytes.concat(abi.encode(index, chainId, address(uint160(0x10 + index)), address(uint160(0x20 + index)), uint256(0)), _root(1, 2, 3, 4));
    }
    function _configBody() private pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(uint256(1), uint256(42), uint256(524288), bytes32(uint256(7)), uint256(2)),
            _chain(1, 100), _chain(7, 200),
            abi.encode(uint256(7), address(13), address(14), uint256(1), uint256(18), uint256(32), uint256(32))
        );
    }
    function _configHash() private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Config"), _configBody()));
    }
    function _header(uint256 deposits, uint256 withdrawals, uint256 rewards) private pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(uint256(4), _configHash(), uint256(9)),
            _root(1, 2, 3, 4), _root(5, 6, 7, 8),
            abi.encode(uint256(2), deposits, withdrawals, rewards)
        );
    }
    function _row(uint256 index, uint256 oldCount, uint256 newCount) private pure returns (bytes memory) {
        return bytes.concat(abi.encode(index, uint256(0)), _root(1, 2, 3, 4), _root(5, 6, 7, 8), _root(5, 6, 7, 8), abi.encode(oldCount, newCount));
    }
    function _deposit(uint256 index, uint256 absoluteIndex) private pure returns (bytes memory) {
        return abi.encode(index, absoluteIndex, bytes32(uint256(9)), address(0x1234), bytes32(uint256(8)), uint256(11), bytes32(uint256(12)));
    }
    function _withdrawal(uint256 chain, uint256 user, uint256 contractId, uint256 nonce, uint256 amount) private pure returns (bytes memory) {
        return abi.encode(uint256(1), chain, user, contractId, bytes32(nonce), uint256(0), uint256(0), uint256(0), address(15), amount);
    }
    function _reward(uint256 chain, uint256 user, uint256 contractId, uint256 count, uint256 amount) private pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(uint256(2), chain, user, contractId),
            _root(1, 0, 0, 0), _root(2, 0, 0, 0),
            abi.encode(count, address(15), amount)
        );
    }
    function _canonical() private pure returns (bytes memory) {
        return bytes.concat(
            _header(1, 1, 1), _row(1, 0, 0), _row(7, 4, 5), _deposit(7, 4),
            _withdrawal(1, 7, 0x010203, 9, 5), _reward(7, 7, 7, 1, 5)
        );
    }
    function _replace(bytes memory body, uint256 index, uint256 value) private pure returns (bytes memory) {
        assembly ("memory-safe") { mstore(add(add(body, 32), mul(index, 32)), value) }
        return body;
    }

    function testCanonicalOpeningMatchesNativeWordOrder() public view {
        bytes memory body = _canonical();
        assertEq(body.length, 32 * (15 + 16 * 2 + 7 + 10 + 15));
        BridgeOpening.BridgeOpeningBody memory opening = harness.readBridgeOpening(_configBody(), body);
        assertEq(opening.configHash, _configHash());
        assertEq(opening.endCheckpointId, 9);
        assertEq(opening.endCheckpointRoot, _packed(1, 2, 3, 4));
        assertEq(opening.endUserRoot, _packed(5, 6, 7, 8));
        assertEq(opening.chains.length, 2);
        assertEq(opening.chains[1].chainIndex, 7);
        assertEq(opening.chains[1].startCheckpointId, 0);
        assertEq(opening.chains[1].oldCount, 4);
        assertEq(opening.chains[1].newCount, 5);
        assertEq(opening.deposits.length, 1);
        assertEq(opening.deposits[0].chainIndex, 7);
        assertEq(opening.deposits[0].absoluteIndex, 4);
        assertEq(opening.deposits[0].token, address(0x1234));
        assertEq(opening.withdrawals.length, 1);
        assertEq(opening.withdrawals[0].chainIndex, 1);
        assertEq(opening.withdrawals[0].userId, 7);
        assertEq(opening.withdrawals[0].contractId, 0x010203);
        assertEq(opening.withdrawals[0].nonce, bytes32(uint256(9)));
        assertEq(opening.withdrawals[0].amount, 5);
        assertEq(opening.rewards.length, 1);
        assertEq(opening.rewards[0].userId, 7);
        assertEq(opening.rewards[0].oldNullifierRoot, _packed(1, 0, 0, 0));
        assertEq(opening.rewards[0].newNullifierRoot, _packed(2, 0, 0, 0));
        assertEq(opening.rewards[0].count, 1);
        assertEq(opening.rewards[0].recipient, address(15));
        assertEq(opening.rewards[0].amount, 5);
        assertEq(opening.openingDigest, keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), body)));
    }

    function testMaximumEightByThirtyTwoUsesSingleOpeningDigest() public view {
        bytes memory body = bytes.concat(_header(32, 32, 32), _row(1, 0, 0));
        bytes memory second = bytes.concat(abi.encode(uint256(7), uint256(0)), _root(1, 2, 3, 4), _root(5, 6, 7, 8), _root(9, 0, 0, 0), abi.encode(uint256(0), uint256(32)));
        body = bytes.concat(body, second);
        for (uint256 i; i < 32; ++i) body = bytes.concat(body, _deposit(7, i));
        for (uint256 i; i < 32; ++i) body = bytes.concat(body, _withdrawal(1, i, 1, i + 1, 1));
        for (uint256 i; i < 32; ++i) body = bytes.concat(body, _reward(7, i, 7, 1, 1));
        BridgeOpening.BridgeOpeningBody memory opening = harness.readBridgeOpening(_configBody(), body);
        assertEq(opening.deposits.length, 32);
        assertEq(opening.withdrawals.length, 32);
        assertEq(opening.rewards.length, 32);
        assertEq(opening.openingDigest, keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), body)));
    }

    function testRejectsWrongVersionTrailingAndCountMismatch() public {
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 0, 3));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), bytes.concat(_canonical(), _words(0)));
        bytes memory short = _canonical();
        assembly ("memory-safe") { mstore(short, sub(mload(short), 32)) }
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), short);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 11, 3));
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 14, 33));
    }

    function testRejectsNoncanonicalRootsReservedWordsAndBounds() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 4, P));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 59, 1));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 68, P));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 72, P));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 67, P));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 67, 0));
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 65, 1));
    }

    function testRejectsOrderingChainMembershipAndZeroRows() public {
        bytes memory reversed = bytes.concat(_header(0, 2, 0), _row(1, 0, 0), _row(7, 0, 0), _withdrawal(7, 1, 1, 1, 1), _withdrawal(1, 1, 1, 2, 1));
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        harness.readBridgeOpening(_configBody(), reversed);
        bytes memory unknown = bytes.concat(_header(0, 1, 0), _row(1, 0, 0), _row(7, 0, 0), _withdrawal(3, 1, 1, 1, 1));
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readBridgeOpening(_configBody(), unknown);
        bytes memory empty = bytes.concat(abi.encode(uint256(4), _configHash(), uint256(9)), _root(1, 2, 3, 4), _root(5, 6, 7, 8), abi.encode(uint256(0), uint256(0), uint256(0), uint256(0)));
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readBridgeOpening(_configBody(), empty);
        // A zero-count reward row decodes: the root proof, not the opening decoder, defends protocol emptiness.
        bytes memory repeated = bytes.concat(_header(0, 0, 2), _row(1, 0, 0), _row(7, 0, 0), _reward(7, 1, 7, 0, 1), _reward(7, 1, 7, 1, 1));
        BridgeOpening.BridgeOpeningBody memory replay = harness.readBridgeOpening(_configBody(), repeated);
        assertEq(replay.rewards.length, 2);
        assertEq(replay.rewards[0].count, 0);
        assertEq(replay.rewards[1].oldNullifierRoot, replay.rewards[0].oldNullifierRoot);
    }
    function testEqualCountRejectsChangedDepositRoot() public {
        vm.expectRevert(BridgeOpening.InvalidDepositState.selector);
        harness.readBridgeOpening(_configBody(), _replace(_canonical(), 26, 9));
    }
    function testDepositGroupsCoverTrailingEmptyRows() public view {
        bytes memory leading = bytes.concat(_header(2, 0, 0), _row(1, 0, 2), _row(7, 4, 4), _deposit(1, 0), _deposit(1, 1));
        BridgeOpening.BridgeOpeningBody memory opening = harness.readBridgeOpening(_configBody(), leading);
        assertEq(opening.deposits.length, 2);
        assertEq(opening.deposits[0].chainIndex, 1);
        assertEq(opening.deposits[1].absoluteIndex, 1);
        assertEq(opening.chains[1].oldCount, opening.chains[1].newCount);
        bytes memory middle = bytes.concat(_header(2, 0, 0), _row(1, 3, 3), _row(7, 4, 6), _deposit(7, 4), _deposit(7, 5));
        opening = harness.readBridgeOpening(_configBody(), middle);
        assertEq(opening.deposits[0].chainIndex, 7);
        assertEq(opening.deposits[1].absoluteIndex, 5);
        bytes memory allZero = bytes.concat(_header(0, 0, 0), _row(1, 0, 0), _row(7, 4, 4));
        opening = harness.readBridgeOpening(_configBody(), allZero);
        assertEq(opening.deposits.length, 0);
        assertEq(opening.openingDigest, keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), allZero)));
        bytes memory oneConfig = bytes.concat(
            abi.encode(uint256(1), uint256(42), uint256(524288), bytes32(uint256(7)), uint256(1)),
            _chain(1, 100),
            abi.encode(uint256(1), address(13), address(14), uint256(1), uint256(18), uint256(32), uint256(32))
        );
        bytes32 oneHash = keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Config"), oneConfig));
        bytes memory oneChain = bytes.concat(
            abi.encode(uint256(4), oneHash, uint256(9)), _root(1, 2, 3, 4), _root(5, 6, 7, 8),
            abi.encode(uint256(1), uint256(2), uint256(0), uint256(0)),
            _row(1, 0, 2), _deposit(1, 0), _deposit(1, 1)
        );
        opening = harness.readBridgeOpening(oneConfig, oneChain);
        assertEq(opening.chains.length, 1);
        assertEq(opening.deposits.length, 2);
        assertEq(opening.deposits[1].absoluteIndex, 1);

    }
    function testDepositCountMustMatchEveryRow() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readBridgeOpening(_configBody(), bytes.concat(_header(1, 0, 0), _row(1, 0, 2), _row(7, 4, 4), _deposit(1, 0)));
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readBridgeOpening(_configBody(), bytes.concat(_header(1, 0, 0), _row(1, 0, 0), _row(7, 4, 4), _deposit(1, 0)));
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        harness.readBridgeOpening(_configBody(), bytes.concat(_header(2, 0, 0), _row(1, 0, 0), _row(7, 4, 6), _deposit(7, 5), _deposit(7, 4)));
    }



    function testConfigRetainsTokenWordsWithoutCutover() public view {
        BridgeOpening.NetworkConfig memory config = harness.readConfig(_configBody());
        assertEq(config.networkMagic, 42);
        assertEq(config.chains.length, 2);
        assertEq(config.chains[0].bootstrapId, 0);
        assertEq(config.ethereumIndex, 7);
        assertEq(config.rewardPayer, address(13));
        assertEq(config.rewardToken, address(14));
        assertEq(config.rewardPerClaim, 1);
        assertEq(config.rewardTokenDecimals, 18);
        assertEq(config.maxWithdrawals, 32);
        assertEq(config.maxRewards, 32);
        assertEq(config.configHash, _configHash());
    }
}
