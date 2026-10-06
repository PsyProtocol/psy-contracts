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
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(networkConfig);
        BridgeOpening.DepositAggregateOpening memory deposit = BridgeOpening.readDepositAggregate(w.deposits, config);
        BridgeOpening.SettlementOpening memory settlement = BridgeOpening.readSettlementOpening(w.settlement, config, deposit.depositOpeningDigest);
        vm.expectCall(address(finalizeVerifier), abi.encodeCall(finalizeVerifier.verifyProof, (w.settlementProof, BridgeOpening.proofInputs(settlement.openingDigest))));
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
        bytes memory settlement = mismatched.settlement;
        assembly ("memory-safe") { mstore(add(settlement, 800), 9) }
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        _apply(mismatched);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
    }

    function testEmptyPayoutsStillRequireSettlementProof() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        assertGt(w.settlementProof[0], 0);
        assertGt(w.depositProof[0], 0);
        vm.prank(proposer);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function testBootstrapIdentityAndZeroFinalizeProofRejected() public {
        _deployAtomic(owner, proposer);
        Window memory identity = _emptyWindow(0, bytes32(0));
        vm.prank(proposer);
        _apply(identity);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        Window memory positive = _emptyWindow(1, bytes32(uint256(1)));
        positive.settlementProof[0] = 0;
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
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        _apply(replay);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
    }

    function testRejectsMissingEndpointRow() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        bytes memory settlement = w.settlement;
        assembly ("memory-safe") { mstore(settlement, sub(mload(settlement), 32)) }
        vm.prank(proposer);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
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
