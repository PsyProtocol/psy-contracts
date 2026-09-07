// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {StateManager} from "../../src/StateManager.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {MockGnarkVerifier} from "../fixtures/contracts/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

contract ExpectedFinalizeHashVerifier {
    bytes32 internal immutable expectedHash;

    constructor(bytes32 expectedHash_) {
        expectedHash = expectedHash_;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata publicInputs) external view {
        bytes32 actualHash = bytes32((uint256(publicInputs[0]) << 128) | uint256(publicInputs[1]));
        require(actualHash == expectedHash, "unexpected hash");
    }
}

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

    function _pairSwapU32x8(bytes32 root) internal pure returns (bytes32) {
        uint256 x = uint256(root);
        return bytes32(
            (x & (uint256(0xffffffff) << 192)) << 32 |
            (x & (uint256(0xffffffff) << 224)) >> 32 |
            (x & (uint256(0xffffffff) << 128)) << 32 |
            (x & (uint256(0xffffffff) << 160)) >> 32 |
            (x & (uint256(0xffffffff) << 64)) << 32 |
            (x & (uint256(0xffffffff) << 96)) >> 32 |
            (x & uint256(0xffffffff)) << 32 |
            (x & (uint256(0xffffffff) << 32)) >> 32
        );
    }

    function _expectedFinalizeHash(
        bytes32[2] memory checkpointRoots,
        bytes32 depositTreeRoot,
        bytes32 withdrawalTreeRoot,
        uint64 terminalCheckpointId,
        uint64 numCheckpointsAggregated
    ) internal pure returns (bytes32) {
        uint256 oldRoot = uint256(checkpointRoots[0]);
        uint256 newRoot = uint256(checkpointRoots[1]);
        return keccak256(
            abi.encodePacked(
                uint64(oldRoot),
                uint64(oldRoot >> 64),
                uint64(oldRoot >> 128),
                uint64(oldRoot >> 192),
                _pairSwapU32x8(depositTreeRoot),
                _pairSwapU32x8(withdrawalTreeRoot),
                uint64(newRoot),
                uint64(newRoot >> 64),
                uint64(newRoot >> 128),
                uint64(newRoot >> 192),
                terminalCheckpointId,
                numCheckpointsAggregated
            )
        );
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
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(startRoot, endRoot),
            withdrawalRoot,
            0,
            10,
            depositProof,
            withdrawalProof
        );

        assertEq(sm.lastVerifiedCheckpointRoot(), endRoot);
        assertEq(sm.lastVerifiedDepositTreeRoot(), depositRoot);
        assertEq(sm.lastVerifiedWithdrawalTreeRoot(), withdrawalRoot);
        assertEq(sm.withdrawalSubtreeRoot(), withdrawalProof[0]);
        assertEq(sm.lastFinalizedCheckpointId(), 10);
    }

    function testFinalizeHashBindsTerminalCheckpointIdAndCount() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        StateManager sm = _deployStateManager(provider);

        bytes32[2] memory checkpointRoots = _roots(
            bytes32(uint256(0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20)),
            bytes32(uint256(0x2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40))
        );
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(bytes32(0), 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0xAA)), 0);
        uint64 terminalCheckpointId = 37;
        uint64 numCheckpointsAggregated = 37;
        ExpectedFinalizeHashVerifier verifier = new ExpectedFinalizeHashVerifier(
            _expectedFinalizeHash(
                checkpointRoots,
                depositRoot,
                withdrawalRoot,
                terminalCheckpointId,
                numCheckpointsAggregated
            )
        );

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        vm.stopPrank();

        vm.prank(proposer);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            checkpointRoots,
            withdrawalRoot,
            0,
            terminalCheckpointId,
            depositProof,
            withdrawalProof
        );

        assertEq(sm.lastFinalizedCheckpointId(), terminalCheckpointId);
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
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(1)), bytes32(uint256(2))),
            withdrawalRoot,
            0,
            10,
            depositProof,
            withdrawalProof
        );

        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(9)), bytes32(uint256(3))),
            withdrawalRoot,
            0,
            10,
            depositProof,
            withdrawalProof
        );
    }

    function testFirstFinalizeAllowsZeroWithdrawalBootstrap() public {
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
        bytes32[9] memory withdrawalProof;
        withdrawalProof[3] = bytes32(uint256(0xB00757));

        vm.prank(proposer);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(0), bytes32(uint256(1))),
            bytes32(0),
            0,
            1,
            depositProof,
            withdrawalProof
        );

        assertEq(sm.lastFinalizedCheckpointId(), 1);
    }

    function testZeroWithdrawalBootstrapExpiresAfterNonZeroRoot() public {
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
        bytes32[9] memory zeroWithdrawalProof;

        vm.startPrank(proposer);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(0), bytes32(uint256(1))),
            bytes32(0),
            0,
            1,
            depositProof,
            zeroWithdrawalProof
        );
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(1)), bytes32(uint256(2))),
            bytes32(0),
            0,
            2,
            depositProof,
            zeroWithdrawalProof
        );

        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) =
            _mkTopProof(bytes32(uint256(0xAA)), 0);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(2)), bytes32(uint256(3))),
            withdrawalRoot,
            0,
            3,
            depositProof,
            withdrawalProof
        );

        vm.expectRevert(StateManager.WithdrawalBootstrapExpired.selector);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(3)), bytes32(uint256(4))),
            bytes32(0),
            0,
            4,
            depositProof,
            zeroWithdrawalProof
        );
        vm.stopPrank();
    }


    function testFinalizeRejectsProvenChainIndexMismatch() public {
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
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0xBB)), 0);

        // l1ChainIndex is 0 (set in _deployStateManager). The proof no longer
        // commits to the chain index, so the L1-side calldata guard is the only
        // binding: a mismatched provenChainIndex must revert before any proof
        // or tree validation runs.
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidProvenChainIndex.selector);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(3)), bytes32(uint256(4))),
            withdrawalRoot,
            1,
            11,
            depositProof,
            withdrawalProof
        );
    }
}
