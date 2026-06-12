// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StateManager} from "../../src/StateManager.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {MockGnarkVerifier} from "../../src/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../../src/TestERC1967Proxy.sol";

contract StateManagerFinalizeTest is Test {
    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);

    function _roots(bytes32 first, bytes32 last) internal pure returns (bytes32[2] memory r) {
        r[0] = first;
        r[1] = last;
    }

    function _mkTopProof(bytes32 leaf, uint8 index) internal pure returns (bytes32[9] memory p, bytes32 root) {
        p[0] = leaf;
        bytes32 cur = leaf;
        for (uint8 i = 0; i < 8; ++i) {
            // deterministic non-zero sibling
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

    function _dummyGnarkProof() internal pure returns (bytes memory proof) {
        uint256[8] memory proofWords = [uint256(1), 2, 3, 4, 5, 6, 7, 8];
        return abi.encode(proofWords);
    }

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

    function testFinalizeSuccessAndAdvanceState() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        vm.stopPrank();

        bytes32 startRoot = bytes32(uint256(1));
        bytes32 endRoot = bytes32(uint256(2));
        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0xAA)), 0);

        vm.prank(proposer);
        sm.finalize(_dummyGnarkProof(), depositRoot, _roots(startRoot, endRoot), withdrawalRoot, 7, 10, depositProof, withdrawalProof);

        assertEq(sm.lastVerifiedCheckpointRoot(), endRoot);
        assertEq(sm.lastVerifiedDepositTreeRoot(), depositRoot);
        assertEq(sm.lastVerifiedWithdrawalTreeRoot(), withdrawalRoot);
        assertEq(sm.withdrawalSubtreeRoot(), withdrawalProof[0]);
        assertEq(sm.nextConsumedDepositIndex(), 7);
        assertEq(sm.lastFinalizedCheckpointId(), 10);
    }

    function testFinalizeRejectsContinuityMismatch() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        vm.stopPrank();

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0xAA)), 0);

        vm.prank(proposer);
        sm.finalize(_dummyGnarkProof(), depositRoot, _roots(bytes32(uint256(1)), bytes32(uint256(2))), withdrawalRoot, 1, 10, depositProof, withdrawalProof);

        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        sm.finalize(_dummyGnarkProof(), depositRoot, _roots(bytes32(uint256(9)), bytes32(uint256(3))), withdrawalRoot, 1, 10, depositProof, withdrawalProof);
    }
}
