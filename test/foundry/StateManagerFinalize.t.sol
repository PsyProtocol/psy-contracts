// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StateManager} from "../../src/StateManager.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {AtomicBridgeFixture} from "../fixtures/contracts/AtomicBridgeFixture.sol";

contract StateManagerFinalizeTest is AtomicBridgeFixture {
    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);

    function testFinalizeSuccessAndAdvanceState() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(10, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(w);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
        assertEq(manager.lastFinalizedCheckpointId(), 10);
    }

    function testFinalizeHashBindsTerminalCheckpointIdAndCount() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(37, bytes32(uint256(2)));
        for (uint256 i = 4; i < 20; ++i) w.inputs[i] = i + 1;
        bytes memory encoded = abi.encodePacked(uint64(0), uint64(0), uint64(0), uint64(0));
        for (uint256 i = 4; i < 20; i += 2) {
            encoded = bytes.concat(encoded, abi.encodePacked(uint32(w.inputs[i + 1]), uint32(w.inputs[i])));
        }
        encoded = bytes.concat(encoded, abi.encodePacked(uint64(0), uint64(0), uint64(0), uint64(2), uint64(37), uint64(37)));
        assertEq(encoded.length, 144);
        for (uint256 i = 26; i < 35; ++i) encoded = bytes.concat(encoded, abi.encodePacked(uint64(w.inputs[i])));
        assertEq(encoded.length, 216);
        vm.expectCall(address(finalizeVerifier), abi.encodeCall(finalizeVerifier.verifyProof, (w.finalizeProof, BridgeOpening.proofInputs(keccak256(encoded)))));
        vm.prank(proposer);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 37);
    }

    function testFinalizeRejectsContinuityMismatch() public {
        _deployAtomic(owner, proposer);
        Window memory first = _emptyWindow(10, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(first);
        Window memory mismatched = _emptyWindow(20, bytes32(uint256(3)));
        mismatched.inputs[0] = 9;
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        _apply(mismatched);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
    }

    function testCanonicalEmptyFamiliesUseZeroProofs() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        assertEq(w.withdrawalProof[0], 0);
        assertEq(w.rewardProof[0], 0);
        assertGt(w.depositProof[0], 0);
        vm.prank(proposer);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function testBootstrapIdentityAndZeroFinalizeProofRejected() public {
        _deployAtomic(owner, proposer);
        Window memory identity = _emptyWindow(0, bytes32(0));
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        _apply(identity);
        Window memory positive = _emptyWindow(1, bytes32(uint256(1)));
        positive.finalizeProof[0] = 0;
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidProof.selector);
        _apply(positive);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testPositiveFinalizeReplayPreservesCheckpoint() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(10, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(w);
        Window memory replay = _emptyWindow(10, bytes32(uint256(2)));
        replay.inputs = w.inputs;
        vm.prank(proposer);
        _apply(replay);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
    }

    function testRejectsMissingEndpointRow() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        uint256[] memory inputs = w.inputs;
        assembly ("memory-safe") { mstore(inputs, 26) }
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidProof.selector);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testFinalizeRejectsProvenChainIndexMismatch() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(11, bytes32(uint256(4)));
        bytes memory opening = w.deposits;
        assembly ("memory-safe") { mstore(add(opening, 288), 1) }
        vm.prank(proposer);
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }
}
