// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {StateManager} from "../../src/StateManager.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

contract RejectAggregateProof {
    error RejectedProof();
    function verifyProof(uint256[8] calldata, uint256[2] calldata) external pure { revert RejectedProof(); }
}

contract BridgeAggregateAdmissionTest is Test {
    Bridge private bridge;
    StateManager private manager;
    bytes private config;
    bytes32 private constant EMPTY_ROOT = 0xe479b9bb36c3fc43b1e4dac93c0cde8e29332a714327ba72d65af5933a094e83;

    function domain(string memory label) private pure returns (bytes32) {
        return keccak256(bytes.concat(bytes("PsyBridge/TwoArtifact/1/"), bytes(label)));
    }
    function rootWords(bytes32 root) private pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }
    function setUp() public {
        PsyAddressesProvider provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(new PsyAddressesProvider()), abi.encodeCall(PsyAddressesProvider.initialize, (address(this))))));
        PsyACLManager acl = PsyACLManager(address(new TestERC1967Proxy(address(new PsyACLManager()), abi.encodeCall(PsyACLManager.initialize, (address(this), address(this), address(this), address(this), address(this))))));
        bridge = Bridge(payable(address(new TestERC1967Proxy(address(new Bridge()), ""))));
        manager = StateManager(address(new TestERC1967Proxy(address(new StateManager()), "")));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(manager));
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        config = bytes.concat(
            abi.encode(uint256(1), uint256(0), uint256(524288), bytes32(uint256(7)), uint256(1)),
            abi.encode(uint256(1), block.chainid, address(bridge), address(manager), uint256(0)), rootWords(bytes32(0)),
            abi.encode(uint256(1), address(13), address(14), uint256(1), uint256(18), uint256(0), uint256(100), uint256(1024), uint256(1024), uint256(1024))
        );
        RejectAggregateProof verifier = new RejectAggregateProof();
        bridge.initialize(address(this), address(provider), config, 1, address(verifier));
        manager.initialize(address(this), address(provider), 1, config, address(verifier));
    }
    function openingA() private view returns (bytes memory) {
        bytes32 configHash = keccak256(bytes.concat(domain("Config"), config));
        bytes memory end = bytes.concat(abi.encode(uint256(0)), rootWords(bytes32(0)));
        bytes memory starts = bytes.concat(abi.encode(uint256(1), uint256(1), uint256(0)), rootWords(bytes32(0)));
        bytes memory deposits = bytes.concat(abi.encode(uint256(1), uint256(1)), rootWords(EMPTY_ROOT), rootWords(EMPTY_ROOT), abi.encode(uint256(0), uint256(0)));
        bytes32 windowId = keccak256(bytes.concat(domain("Window"), configHash, end, starts, deposits));
        return bytes.concat(abi.encode(configHash, windowId), end, starts, deposits, abi.encode(uint256(0)));
    }
    function openingB() private view returns (bytes memory) {
        return bytes.concat(openingA(), abi.encode(uint256(1), uint256(1)), rootWords(EMPTY_ROOT), abi.encode(uint256(0)), rootWords(bytes32(0)), abi.encode(uint256(0), uint256(0)));
    }
    function testDepositRetryCannotBypassVerifier() public {
        uint256[8] memory proof;
        vm.expectRevert(RejectAggregateProof.RejectedProof.selector);
        bridge.applyDepositAggregate(proof, openingA());
        assertEq(bridge.depositRoot(), EMPTY_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
    }
    function testIdentityCheckpointCannotBypassVerifier() public {
        uint256[8] memory proof;
        vm.expectRevert(RejectAggregateProof.RejectedProof.selector);
        manager.finalizeCheckpointAggregate(proof, openingB());
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(0));
    }
    function testIdentityEventWithoutStorageWritesWithTestOnlyVerifierMock() public {
        uint256[8] memory proof;
        bytes memory opening = openingB();
        BridgeOpening.BOpening memory decoded = BridgeOpening.readB(opening, BridgeOpening.readConfig(config));
        bytes memory verifierCall = abi.encodeWithSelector(RejectAggregateProof.verifyProof.selector, proof, BridgeOpening.proofInputs(decoded.statementB));
        // Tests orchestration only; real generated proof verification remains a separate QA gate.
        vm.mockCall(manager.aggregateVerifier(), verifierCall, bytes(""));
        vm.expectCall(manager.aggregateVerifier(), verifierCall);
        vm.record();
        vm.recordLogs();
        manager.finalizeCheckpointAggregate(proof, opening);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, bytes32[] memory managerWrites) = vm.accesses(address(manager));
        (, bytes32[] memory bridgeWrites) = vm.accesses(address(bridge));
        assertEq(managerWrites.length, 0);
        assertEq(bridgeWrites.length, 0);
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(manager));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], keccak256("AggregateFinalized(bytes32,uint64,bytes32,bytes32,uint32,bytes32)"));
        assertEq(logs[0].topics[1], decoded.statementB);
        assertEq(logs[0].data, abi.encode(decoded.a.endCheckpointId, decoded.a.endCheckpointRoot, EMPTY_ROOT, uint32(0), bytes32(0)));
        vm.clearMockedCalls();
    }
    function testOnlyConfiguredStateManagerRegistersWithdrawals() public {
        BridgeOpening.WithdrawalLeaf[] memory withdrawals = new BridgeOpening.WithdrawalLeaf[](1);
        withdrawals[0] = BridgeOpening.WithdrawalLeaf(1, 7, address(15), address(0), 1, bytes32(uint256(1)));
        vm.expectRevert(Bridge.OnlyStateManager.selector);
        bridge.registerAggregateWithdrawals(withdrawals);
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(1))));
    }
    function testProviderProposerAclStillRequired() public {
        uint256[8] memory proof;
        bytes memory opening = openingB();
        vm.prank(address(99));
        vm.expectRevert(StateManager.OnlyProposer.selector);
        manager.finalizeCheckpointAggregate(proof, opening);
    }
}
