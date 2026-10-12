// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {StateManager} from "../../src/StateManager.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {AtomicBridgeFixture} from "./fixtures/AtomicBridgeFixture.sol";

contract StateManagerFinalizeTest is AtomicBridgeFixture {
    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);

    function setUp() public { _deployAtomic(owner, proposer); }

    function testFinalizeSuccessAndAdvanceState() public {
        Opening memory a = _emptyOpening(10, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(a);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
        assertEq(manager.lastFinalizedCheckpointId(), 10);
        assertEq(manager.depositSubtreeRoot(), atomicBridge.depositRoot());
    }

    function testVerifierReceivesCompleteOpeningDigest() public {
        Opening memory a = _emptyOpening(37, bytes32(uint256(2)));
        bytes32 digest = keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), a.opening));
        vm.expectCall(address(openingVerifier), abi.encodeCall(openingVerifier.verifyProof, (a.proof, BridgeOpening.proofInputs(digest))));
        vm.prank(proposer);
        _apply(a);
        assertTrue(manager.appliedOpenings(digest));
    }

    function testRejectsStaleStartWithoutAcceptingAlteredOpening() public {
        Opening memory first = _emptyOpening(10, bytes32(uint256(2)));
        Opening memory stale = _emptyOpening(20, bytes32(uint256(3)));
        vm.prank(proposer);
        _apply(first);
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        _apply(stale);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
    }

    function testExactAcceptedOpeningRetryDoesNotAdvanceOrVerifyAgain() public {
        Opening memory a = _emptyOpening(10, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(a);
        openingVerifier.setShouldVerify(false);
        vm.recordLogs();
        vm.prank(proposer);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != StateManager.Finalized.selector);
        }
    }

    function testNewSameEndpointOpeningRequiresProof() public {
        Opening memory first = _emptyOpening(10, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(first);
        Opening memory next = _emptyOpening(10, bytes32(uint256(2)));
        openingVerifier.setShouldVerify(false);
        vm.prank(proposer);
        vm.expectRevert(bytes("invalid proof"));
        _apply(next);
        openingVerifier.setShouldVerify(true);
        vm.prank(proposer);
        _apply(next);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
    }

    function testBootstrapIdentityRequiresNonzeroProof() public {
        Opening memory a = _emptyOpening(0, bytes32(0));
        a.proof[0] = 0;
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidProof.selector);
        _apply(a);
        a.proof[0] = 1;
        vm.prank(proposer);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testRejectsTruncatedOpening() public {
        Opening memory a = _emptyOpening(1, bytes32(uint256(1)));
        bytes memory encoded = a.opening;
        assembly ("memory-safe") { mstore(encoded, sub(mload(encoded), 32)) }
        vm.prank(proposer);
        vm.expectRevert();
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testRejectsChangedAcceptedOpeningEndpoint() public {
        Opening memory a = _emptyOpening(1, bytes32(uint256(1)));
        vm.prank(proposer);
        _apply(a);
        bytes memory encoded = a.opening;
        assembly ("memory-safe") { mstore(add(encoded, 96), 2) }
        vm.prank(proposer);
        vm.expectRevert();
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }
}
