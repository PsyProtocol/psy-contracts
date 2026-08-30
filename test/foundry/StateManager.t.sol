// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StateManager} from "../../src/StateManager.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {MockGnarkVerifier} from "../../src/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../../src/TestERC1967Proxy.sol";

contract StateManagerTest is Test {
    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);
    address internal other = address(0xC0DE);

    function _deployAddressesProvider() internal returns (PsyAddressesProvider provider) {
        PsyAddressesProvider impl = new PsyAddressesProvider();
        bytes memory initData = abi.encodeCall(PsyAddressesProvider.initialize, (owner));
        provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployACL() internal returns (PsyACLManager acl) {
        PsyACLManager impl = new PsyACLManager();
        bytes memory initData = abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, proposer));
        acl = PsyACLManager(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployStateManager(PsyAddressesProvider provider) internal returns (StateManager sm) {
        StateManager impl = new StateManager();
        bytes memory initData = abi.encodeCall(StateManager.initialize, (owner, address(provider), uint8(0)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        sm = StateManager(address(proxy));
    }

    function _dummyGnarkProof() internal pure returns (bytes memory proof) {
        uint256[8] memory proofWords = [uint256(1), 2, 3, 4, 5, 6, 7, 8];
        return abi.encode(proofWords);
    }

    function testOnlyProposerCanFinalize() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        vm.stopPrank();

        bytes32[2] memory roots = [bytes32(0), bytes32(0)];
        bytes32[9] memory proofZero;
        vm.prank(other);
        vm.expectRevert(StateManager.OnlyProposer.selector);
        sm.finalize(_dummyGnarkProof(), bytes32(0), roots, bytes32(0), 0, 1, proofZero, proofZero);

        vm.prank(proposer);
        sm.finalize(_dummyGnarkProof(), bytes32(0), roots, bytes32(0), 0, 1, proofZero, proofZero);
        assertEq(sm.lastFinalizedCheckpointId(), 1);
    }

    function testOwnerCanRotateBridge() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.BRIDGE_ID(), other);
        vm.stopPrank();
        assertEq(provider.getAddress(provider.BRIDGE_ID()), other);
        assertEq(sm.l1ChainIndex(), 0);
    }

    function _nonMappingState(
        uint64 checkpointId,
        uint256 checkpointRoot,
        uint256 depositTreeRoot,
        uint256 withdrawalTreeRoot,
        uint256 withdrawalRoot
    ) internal pure returns (StateManager.NonMappingState memory state_) {
        state_ = StateManager.NonMappingState({
            lastFinalizedCheckpointId: checkpointId,
            lastVerifiedCheckpointRoot: bytes32(checkpointRoot),
            lastVerifiedDepositTreeRoot: bytes32(depositTreeRoot),
            lastVerifiedWithdrawalTreeRoot: bytes32(withdrawalTreeRoot),
            withdrawalSubtreeRoot: bytes32(withdrawalRoot)
        });
    }

    function testResetNonMappingStateRestoresFieldsLeavesMappingsAndRetryIsNoOp() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        StateManager sm = _deployStateManager(provider);

        bytes32 aclManagerId = provider.ACL_MANAGER_ID();
        vm.prank(owner);
        provider.setAddress(aclManagerId, address(acl));

        bytes32 knownDepositRoot = bytes32(uint256(0xD0));
        bytes32 knownWithdrawalRoot = bytes32(uint256(0xA0));
        vm.prank(owner);
        sm.forceSetState(10, bytes32(uint256(0x11)), bytes32(uint256(0x12)), knownDepositRoot, bytes32(uint256(0x13)), knownWithdrawalRoot);

        StateManager.NonMappingState memory expected = _nonMappingState(10, 0x11, 0x12, 0x13, 0xA0);
        StateManager.NonMappingState memory target = _nonMappingState(4, 0x21, 0x22, 0x23, 0x24);

        vm.recordLogs();
        vm.prank(owner);
        sm.resetNonMappingState(expected, target);
        Vm.Log[] memory resetLogs = vm.getRecordedLogs();
        assertEq(resetLogs.length, 1);
        assertEq(resetLogs[0].topics[0], StateManager.NonMappingStateReset.selector);

        assertEq(sm.lastFinalizedCheckpointId(), target.lastFinalizedCheckpointId);
        assertEq(sm.lastVerifiedCheckpointRoot(), target.lastVerifiedCheckpointRoot);
        assertEq(sm.lastVerifiedDepositTreeRoot(), target.lastVerifiedDepositTreeRoot);
        assertEq(sm.lastVerifiedWithdrawalTreeRoot(), target.lastVerifiedWithdrawalTreeRoot);
        assertEq(sm.withdrawalSubtreeRoot(), target.withdrawalSubtreeRoot);
        assertTrue(sm.knownDepositSubtreeRoots(knownDepositRoot));
        assertTrue(sm.knownWithdrawalSubtreeRoots(knownWithdrawalRoot));
        assertFalse(sm.knownDepositSubtreeRoots(target.lastVerifiedDepositTreeRoot));
        assertFalse(sm.knownWithdrawalSubtreeRoots(target.withdrawalSubtreeRoot));

        vm.recordLogs();
        vm.prank(owner);
        sm.resetNonMappingState(expected, target);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testResetNonMappingStateFailsClosedOnAuthCasAndDirection() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        StateManager sm = _deployStateManager(provider);

        bytes32 aclManagerId = provider.ACL_MANAGER_ID();
        vm.prank(owner);
        provider.setAddress(aclManagerId, address(acl));

        StateManager.NonMappingState memory initial = _nonMappingState(0, 0, 0, 0, 0);
        vm.prank(other);
        vm.expectRevert(StateManager.UnauthorizedStateManagerAdmin.selector);
        sm.resetNonMappingState(initial, initial);

        vm.prank(owner);
        sm.forceSetState(10, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(4)), bytes32(uint256(5)));

        StateManager.NonMappingState memory current = _nonMappingState(10, 1, 2, 4, 5);
        StateManager.NonMappingState memory stale = _nonMappingState(9, 1, 2, 4, 5);
        StateManager.NonMappingState memory rollbackTarget = _nonMappingState(8, 6, 7, 8, 9);
        vm.prank(owner);
        vm.expectPartialRevert(StateManager.UnexpectedCurrentState.selector);
        sm.resetNonMappingState(stale, rollbackTarget);

        StateManager.NonMappingState memory forwardTarget = _nonMappingState(11, 6, 7, 8, 9);
        vm.prank(owner);
        vm.expectRevert(StateManager.InvalidRollbackTarget.selector);
        sm.resetNonMappingState(current, forwardTarget);

        assertEq(sm.lastFinalizedCheckpointId(), 10);
        assertEq(sm.lastVerifiedCheckpointRoot(), bytes32(uint256(1)));
    }
}
