// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";

contract BridgeOpeningHarness {
    function readA(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readA(opening, BridgeOpening.readConfig(config)).statementA;
    }
    function readB(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readB(opening, BridgeOpening.readConfig(config)).statementB;
    }
}

contract BridgeOpeningTest is Test {
    BridgeOpeningHarness private harness = new BridgeOpeningHarness();

    function domain(string memory label) private pure returns (bytes32) {
        return keccak256(bytes.concat(bytes("PsyBridge/TwoArtifact/1/"), bytes(label)));
    }
    function configBytes() private pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(uint256(1), uint256(0), uint256(524288), bytes32(uint256(7)), uint256(1)),
            abi.encode(uint256(1), uint256(1), address(11), address(12), uint256(0), uint256(1), uint256(2), uint256(3), uint256(4)),
            abi.encode(uint256(1), address(13), address(14), uint256(1), uint256(18), uint256(0), uint256(100), uint256(1024), uint256(1024), uint256(1024))
        );
    }
    function openingA() private pure returns (bytes memory) {
        bytes32 configHash = keccak256(bytes.concat(domain("Config"), configBytes()));
        bytes memory end = abi.encode(uint256(0), uint256(1), uint256(2), uint256(3), uint256(4));
        bytes memory starts = abi.encode(uint256(1), uint256(1), uint256(0), uint256(1), uint256(2), uint256(3), uint256(4));
        bytes memory deposits = abi.encode(uint256(1), uint256(1), uint256(5), uint256(6), uint256(7), uint256(8), uint256(5), uint256(6), uint256(7), uint256(8), uint256(0), uint256(0));
        bytes32 windowId = keccak256(bytes.concat(domain("Window"), configHash, end, starts, deposits));
        return bytes.concat(abi.encode(configHash, windowId), end, starts, deposits, abi.encode(uint256(0)));
    }
    function openingB(bytes memory withdrawals, bytes memory rewards) private pure returns (bytes memory) {
        bytes memory ends = abi.encode(uint256(1), uint256(1), uint256(5), uint256(6), uint256(7), uint256(8), uint256(0), uint256(9), uint256(10), uint256(11), uint256(12));
        return bytes.concat(openingA(), ends, withdrawals, rewards);
    }
    function replaceWord(bytes memory body, uint256 index, uint256 value) private pure returns (bytes memory) {
        assembly ("memory-safe") { mstore(add(add(body, 32), mul(index, 32)), value) }
        return body;
    }
    function testEmptyFamiliesUseDistinctPositionBoundDomains() public view {
        bytes memory a = openingA();
        bytes memory projection = new bytes(a.length - 32);
        for (uint256 i; i < projection.length; ++i) projection[i] = a[i];
        bytes32 emptyDeposit = keccak256(abi.encode(domain("Empty"), uint256(1), uint256(0)));
        bytes32 expectedA = keccak256(bytes.concat(domain("A"), projection, abi.encode(uint256(0), uint256(0), emptyDeposit)));
        assertEq(harness.readA(configBytes(), a), expectedA);
        bytes memory b = openingB(abi.encode(uint256(0)), abi.encode(uint256(0)));
        bytes memory ends = new bytes(11 * 32);
        for (uint256 i; i < ends.length; ++i) ends[i] = b[a.length + i];
        bytes32 expectedB = keccak256(bytes.concat(domain("B"), expectedA, ends,
            abi.encode(uint256(0), uint256(0), keccak256(abi.encode(domain("Empty"), uint256(2), uint256(0)))),
            abi.encode(uint256(0), uint256(0), keccak256(abi.encode(domain("Empty"), uint256(3), uint256(0))))));
        assertEq(harness.readB(configBytes(), b), expectedB);
    }
    function testRejectsTrailingOpeningWord() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readA(configBytes(), bytes.concat(openingA(), abi.encode(uint256(0))));
    }
    function testRejectsTruncatedFullOpening() public {
        bytes memory a = openingA();
        assembly ("memory-safe") { mstore(a, sub(mload(a), 32)) }
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readA(configBytes(), a);
    }
    function testRejectsNoncanonicalFelt() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readA(configBytes(), replaceWord(openingA(), 3, 18446744069414584321));
    }
    function testRejectsDifferentBridgeIdentity() public {
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readA(replaceWord(configBytes(), 2, 524289), openingA());
    }
    function testRejectsOmittedConfiguredChain() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readA(configBytes(), replaceWord(openingA(), 7, 0));
    }
    function testRejectsAddressHighBits() public {
        bytes memory withdrawal = abi.encode(uint256(1), uint256(1), uint256(7), (uint256(1) << 160) | 15, uint256(0), uint256(1), bytes32(uint256(4)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(withdrawal, abi.encode(uint256(0))));
    }
    function testRejectsDuplicateNonceWithDifferentRecipient() public {
        bytes memory withdrawals = bytes.concat(abi.encode(uint256(2)),
            abi.encode(uint256(1), uint256(7), address(15), address(0), uint256(1), bytes32(uint256(4))),
            abi.encode(uint256(1), uint256(8), address(16), address(0), uint256(1), bytes32(uint256(4))));
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        harness.readB(configBytes(), openingB(withdrawals, abi.encode(uint256(0))));
    }
    function testRejectsAmountAtFieldModulus() public {
        bytes memory withdrawal = abi.encode(uint256(1), uint256(1), uint256(7), address(15), address(0), uint256(18446744069414584321), bytes32(uint256(4)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(withdrawal, abi.encode(uint256(0))));
    }
    function testRejectsRewardOutsideGutaSubtree() public {
        bytes memory rewards = abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(1), uint256(4), address(15));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(abi.encode(uint256(0)), rewards));
    }
    function testRejectsRewardNullifierRelabeling() public {
        bytes memory rewards = abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(0), uint256(4), address(15));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(abi.encode(uint256(0)), rewards));
    }
}
