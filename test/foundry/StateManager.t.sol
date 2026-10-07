// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {StateManager} from "../../src/StateManager.sol";
import {AtomicBridgeFixture} from "./fixtures/AtomicBridgeFixture.sol";

contract StateManagerTest is AtomicBridgeFixture {
    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);
    address internal other = address(0xC0DE);

    function testOnlyProposerCanFinalize() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        vm.prank(other);
        vm.expectRevert(StateManager.OnlyProposer.selector);
        _apply(w);
        vm.prank(proposer);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function testOwnerCanRotateBridge() public {
        _deployAtomic(owner, proposer);
        bytes32 bridgeId = provider.BRIDGE_ID();
        vm.prank(owner);
        provider.setAddress(bridgeId, other);
        assertEq(provider.getAddress(provider.BRIDGE_ID()), other);
        assertEq(manager.l1ChainIndex(), 0);
    }

    function _stateManagerContractState(uint64 checkpointId, uint256 checkpointRoot, uint256 depositTreeRoot, uint256 withdrawalTreeRoot, uint256 withdrawalRoot) internal pure returns (StateManager.StateManagerContractState memory) {
        return StateManager.StateManagerContractState(checkpointId, bytes32(checkpointRoot), bytes32(depositTreeRoot), bytes32(withdrawalTreeRoot), bytes32(withdrawalRoot));
    }

    function testForceSetStateRestoresFieldsLeavesMappingsAndRetryIsNoOp() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(w);
        bytes32 knownDepositRoot = bytes32(uint256(0xD0));
        bytes32 knownWithdrawalRoot = bytes32(uint256(0xA0));
        vm.store(address(manager), keccak256(abi.encode(knownDepositRoot, uint256(5))), bytes32(uint256(1)));
        vm.store(address(manager), keccak256(abi.encode(knownWithdrawalRoot, uint256(6))), bytes32(uint256(1)));
        StateManager.StateManagerContractState memory expected = _stateManagerContractState(1, 2, uint256(manager.lastVerifiedDepositTreeRoot()), uint256(manager.lastVerifiedWithdrawalTreeRoot()), uint256(manager.withdrawalSubtreeRoot()));
        StateManager.StateManagerContractState memory target = _stateManagerContractState(0, 0x21, 0x22, 0x23, 0x24);
        vm.recordLogs();
        vm.prank(owner);
        manager.forceSetState(expected, target);
        Vm.Log[] memory resetLogs = vm.getRecordedLogs();
        assertEq(resetLogs.length, 1);
        assertEq(resetLogs[0].topics[0], StateManager.ForceSetState.selector);
        assertEq(manager.lastFinalizedCheckpointId(), target.lastFinalizedCheckpointId);
        assertEq(manager.lastVerifiedCheckpointRoot(), target.lastVerifiedCheckpointRoot);
        assertEq(manager.lastVerifiedDepositTreeRoot(), target.lastVerifiedDepositTreeRoot);
        assertEq(manager.lastVerifiedWithdrawalTreeRoot(), target.lastVerifiedWithdrawalTreeRoot);
        assertEq(manager.withdrawalSubtreeRoot(), target.withdrawalSubtreeRoot);
        assertTrue(manager.knownDepositSubtreeRoots(knownDepositRoot));
        assertTrue(manager.knownWithdrawalSubtreeRoots(knownWithdrawalRoot));
        assertFalse(manager.knownDepositSubtreeRoots(target.lastVerifiedDepositTreeRoot));
        assertFalse(manager.knownWithdrawalSubtreeRoots(target.withdrawalSubtreeRoot));
        vm.recordLogs();
        vm.prank(owner);
        manager.forceSetState(expected, target);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testForceSetStateFailsClosedOnAuthCasAndDirection() public {
        _deployAtomic(owner, proposer);
        StateManager.StateManagerContractState memory initial = _stateManagerContractState(0, 0, 0, 0, 0);
        vm.prank(other);
        vm.expectRevert(StateManager.UnauthorizedStateManagerAdmin.selector);
        manager.forceSetState(initial, initial);
        Window memory w = _emptyWindow(1, bytes32(uint256(2)));
        vm.prank(proposer);
        _apply(w);
        StateManager.StateManagerContractState memory current = _stateManagerContractState(1, 2, uint256(manager.lastVerifiedDepositTreeRoot()), uint256(manager.lastVerifiedWithdrawalTreeRoot()), uint256(manager.withdrawalSubtreeRoot()));
        StateManager.StateManagerContractState memory stale = _stateManagerContractState(0, 2, uint256(manager.lastVerifiedDepositTreeRoot()), uint256(manager.lastVerifiedWithdrawalTreeRoot()), uint256(manager.withdrawalSubtreeRoot()));
        vm.prank(owner);
        vm.expectPartialRevert(StateManager.UnexpectedCurrentState.selector);
        manager.forceSetState(stale, _stateManagerContractState(0, 6, 7, 8, 9));
        vm.prank(owner);
        vm.expectRevert(StateManager.InvalidForceSetState.selector);
        manager.forceSetState(current, _stateManagerContractState(2, 6, 7, 8, 9));
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
    }

}
