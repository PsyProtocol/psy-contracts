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
}
