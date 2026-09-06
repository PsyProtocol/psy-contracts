// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StateManager} from "../../src/StateManager.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {MockGnarkVerifier} from "../fixtures/contracts/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

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

    function _mkTopProof(bytes32 leaf, uint8 index) internal pure returns (bytes32[9] memory p, bytes32 root) {
        p[0] = leaf;
        bytes32 cur = leaf;
        for (uint8 i = 0; i < 8; ++i) {
            bytes32 sib = keccak256(abi.encodePacked("sib", i));
            p[i + 1] = sib;
            if (((index >> i) & 1) == 0) {
                cur = keccak256(abi.encodePacked(cur, sib));
            } else {
                cur = keccak256(abi.encodePacked(sib, cur));
            }
        }
        root = cur;
    }

    function _roots(bytes32 first, bytes32 last) internal pure returns (bytes32[2] memory r) {
        r[0] = first;
        r[1] = last;
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

    function _stateManagerContractState(
        uint64 checkpointId,
        uint256 checkpointRoot,
        uint256 depositTreeRoot,
        uint256 withdrawalTreeRoot,
        uint256 withdrawalRoot
    ) internal pure returns (StateManager.StateManagerContractState memory state_) {
        state_ = StateManager.StateManagerContractState({
            lastFinalizedCheckpointId: checkpointId,
            lastVerifiedCheckpointRoot: bytes32(checkpointRoot),
            lastVerifiedDepositTreeRoot: bytes32(depositTreeRoot),
            lastVerifiedWithdrawalTreeRoot: bytes32(withdrawalTreeRoot),
            withdrawalSubtreeRoot: bytes32(withdrawalRoot)
        });
    }

    function testForceSetStateRestoresFieldsLeavesMappingsAndRetryIsNoOp() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        vm.stopPrank();

        // Seed live non-mapping storage through the legitimate finalize path.
        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0x1234)), 0);
        vm.prank(proposer);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(1)), bytes32(uint256(2))),
            withdrawalRoot,
            0,
            1,
            depositProof,
            withdrawalProof
        );

        // Mappings are not touched by forceSetState; seed them independently and
        // prove they survive the transition.
        bytes32 knownDepositRoot = bytes32(uint256(0xD0));
        bytes32 knownWithdrawalRoot = bytes32(uint256(0xA0));
        vm.store(address(sm), keccak256(abi.encode(knownDepositRoot, uint256(5))), bytes32(uint256(1)));
        vm.store(address(sm), keccak256(abi.encode(knownWithdrawalRoot, uint256(6))), bytes32(uint256(1)));
        assertTrue(sm.knownDepositSubtreeRoots(knownDepositRoot));
        assertTrue(sm.knownWithdrawalSubtreeRoots(knownWithdrawalRoot));

        StateManager.StateManagerContractState memory expected = _stateManagerContractState(1, 2, uint256(depositRoot), uint256(withdrawalRoot), uint256(withdrawalProof[0]));
        StateManager.StateManagerContractState memory target = _stateManagerContractState(0, 0x21, 0x22, 0x23, 0x24);

        vm.recordLogs();
        vm.prank(owner);
        sm.forceSetState(expected, target);
        Vm.Log[] memory resetLogs = vm.getRecordedLogs();
        assertEq(resetLogs.length, 1);
        assertEq(resetLogs[0].topics[0], StateManager.ForceSetState.selector);

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
        sm.forceSetState(expected, target);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testForceSetStateFailsClosedOnAuthCasAndDirection() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        vm.stopPrank();

        StateManager.StateManagerContractState memory initial = _stateManagerContractState(0, 0, 0, 0, 0);
        vm.prank(other);
        vm.expectRevert(StateManager.UnauthorizedStateManagerAdmin.selector);
        sm.forceSetState(initial, initial);

        // Seed live non-mapping storage through the legitimate finalize path.
        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0x1234)), 0);
        vm.prank(proposer);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(1)), bytes32(uint256(2))),
            withdrawalRoot,
            0,
            1,
            depositProof,
            withdrawalProof
        );

        StateManager.StateManagerContractState memory current = _stateManagerContractState(1, 2, uint256(depositRoot), uint256(withdrawalRoot), uint256(withdrawalProof[0]));
        StateManager.StateManagerContractState memory stale = _stateManagerContractState(0, 2, uint256(depositRoot), uint256(withdrawalRoot), uint256(withdrawalProof[0]));
        StateManager.StateManagerContractState memory rollbackTarget = _stateManagerContractState(0, 6, 7, 8, 9);
        vm.prank(owner);
        vm.expectPartialRevert(StateManager.UnexpectedCurrentState.selector);
        sm.forceSetState(stale, rollbackTarget);

        StateManager.StateManagerContractState memory forwardTarget = _stateManagerContractState(2, 6, 7, 8, 9);
        vm.prank(owner);
        vm.expectRevert(StateManager.InvalidForceSetState.selector);
        sm.forceSetState(current, forwardTarget);

        assertEq(sm.lastFinalizedCheckpointId(), 1);
        assertEq(sm.lastVerifiedCheckpointRoot(), bytes32(uint256(2)));
        assertEq(sm.lastVerifiedDepositTreeRoot(), depositRoot);
        assertEq(sm.lastVerifiedWithdrawalTreeRoot(), withdrawalRoot);
        assertEq(sm.withdrawalSubtreeRoot(), withdrawalProof[0]);
    }
}
