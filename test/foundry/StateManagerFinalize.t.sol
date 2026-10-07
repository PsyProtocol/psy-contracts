// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Bridge} from "../../src/Bridge.sol";
import {StateManager} from "../../src/StateManager.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {AtomicBridgeFixture} from "./fixtures/AtomicBridgeFixture.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

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
        BridgeOpening.WindowFinalizationOpening memory windowFinalization = BridgeOpening.readWindowFinalizationOpening(w.windowFinalizationOpening, config, deposit.depositOpeningDigest);
        vm.expectCall(address(finalizeVerifier), abi.encodeCall(finalizeVerifier.verifyProof, (w.windowFinalizationProof, BridgeOpening.proofInputs(windowFinalization.openingDigest))));
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
        bytes memory windowFinalizationOpening = mismatched.windowFinalizationOpening;
        assembly ("memory-safe") { mstore(add(windowFinalizationOpening, 800), 9) }
        vm.prank(proposer);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        _apply(mismatched);
        assertEq(manager.lastFinalizedCheckpointId(), 10);
    }

    function testEmptyPayoutsStillRequireWindowFinalizationProof() public {
        _deployAtomic(owner, proposer);
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        assertGt(w.windowFinalizationProof[0], 0);
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
        positive.windowFinalizationProof[0] = 0;
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
        bytes memory windowFinalizationOpening = w.windowFinalizationOpening;
        assembly ("memory-safe") { mstore(windowFinalizationOpening, sub(mload(windowFinalizationOpening), 32)) }
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

contract MixedCursorVerifier {
    function endpointChainListHash() external pure returns (bytes32) {
        return keccak256(abi.encodePacked("PsyBridge/FinalizeChainList/1", uint16(2), uint8(0), uint8(1)));
    }
    function verifyProof(uint256[8] calldata, uint256[2] calldata) external pure {}
}

contract StateManagerMixedCursorTest is AtomicBridgeFixture {
    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);
    uint256 internal constant CHAIN_ZERO = 111;
    uint256 internal constant CHAIN_ONE = 222;

    function testMixedCursorOnBothDestinations() public {
        MixedCursorVerifier verifier = new MixedCursorVerifier();
        PsyACLManager acl = PsyACLManager(address(new TestERC1967Proxy(address(new PsyACLManager()), abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, proposer)))));
        PsyAddressesProvider providerImpl = new PsyAddressesProvider();
        Bridge bridgeImpl = new Bridge();
        StateManager managerImpl = new StateManager();
        uint64 ownerNonce = vm.getNonce(owner);
        address provider0 = vm.computeCreateAddress(owner, ownerNonce);
        address provider1 = vm.computeCreateAddress(owner, ownerNonce + 1);
        address bridge0 = vm.computeCreateAddress(owner, ownerNonce + 2);
        address manager0 = vm.computeCreateAddress(owner, ownerNonce + 3);
        address bridge1 = vm.computeCreateAddress(owner, ownerNonce + 4);
        address manager1 = vm.computeCreateAddress(owner, ownerNonce + 5);
        bytes32 root9 = bytes32(uint256(9));
        bytes32 root10 = bytes32(uint256(10));
        bytes memory config = bytes.concat(
            abi.encode(uint256(1), uint256(42), uint256(524288), bytes32(uint256(7)), uint256(2)),
            abi.encode(uint256(0), CHAIN_ZERO, bridge0, manager0, uint256(9)), _rootWords(root9),
            abi.encode(uint256(1), CHAIN_ONE, bridge1, manager1, uint256(10)), _rootWords(root10),
            abi.encode(uint256(0), address(13), address(14), uint256(1), uint256(18), uint256(0), uint256(1000), uint256(1024), uint256(1024), uint256(1024))
        );
        vm.startPrank(owner);
        PsyAddressesProvider deployed0 = PsyAddressesProvider(address(new TestERC1967Proxy(address(providerImpl), abi.encodeCall(PsyAddressesProvider.initialize, (owner)))));
        deployed0.setAddress(deployed0.ACL_MANAGER_ID(), address(acl));
        deployed0.setAddress(deployed0.BRIDGE_ID(), bridge0);
        deployed0.setAddress(deployed0.STATE_MANAGER_ID(), manager0);
        PsyAddressesProvider deployed1 = PsyAddressesProvider(address(new TestERC1967Proxy(address(providerImpl), abi.encodeCall(PsyAddressesProvider.initialize, (owner)))));
        deployed1.setAddress(deployed1.ACL_MANAGER_ID(), address(acl));
        deployed1.setAddress(deployed1.BRIDGE_ID(), bridge1);
        deployed1.setAddress(deployed1.STATE_MANAGER_ID(), manager1);
        vm.chainId(CHAIN_ZERO);
        Bridge deployedBridge0 = Bridge(payable(address(new TestERC1967Proxy(address(bridgeImpl), abi.encodeCall(Bridge.initialize, (owner, provider0, config, uint8(0)))))));
        StateManager deployedManager0 = StateManager(address(new TestERC1967Proxy(address(managerImpl), abi.encodeCall(StateManager.initialize, (owner, provider0, uint8(0), config, address(verifier), address(verifier), address(verifier), address(verifier))))));
        vm.chainId(CHAIN_ONE);
        Bridge deployedBridge1 = Bridge(payable(address(new TestERC1967Proxy(address(bridgeImpl), abi.encodeCall(Bridge.initialize, (owner, provider1, config, uint8(1)))))));
        StateManager deployedManager1 = StateManager(address(new TestERC1967Proxy(address(managerImpl), abi.encodeCall(StateManager.initialize, (owner, provider1, uint8(1), config, address(verifier), address(verifier), address(verifier), address(verifier))))));
        vm.stopPrank();
        bytes32 depositRoot = deployedBridge0.depositRoot();
        bytes memory deposits = _mixedDeposits(config, root9, root10, depositRoot);
        bytes memory windowFinalizationOpening = _mixedWindowFinalization(deposits, root9, depositRoot);
        BridgeOpening.NetworkConfig memory parsed = BridgeOpening.readConfig(config);
        BridgeOpening.DepositAggregateOpening memory opening = BridgeOpening.readDepositAggregate(deposits, parsed);
        BridgeOpening.WindowFinalizationOpening memory decoded = BridgeOpening.readWindowFinalizationOpening(windowFinalizationOpening, parsed, opening.depositOpeningDigest);
        assertEq(opening.starts[0].startCheckpointId, 9);
        assertEq(opening.starts[1].startCheckpointId, 10);
        assertEq(decoded.finalizations[0].startCheckpointRoot, root9);
        assertEq(decoded.finalizations[1].startCheckpointRoot, root9);
        assertEq(opening.starts[1].startCheckpointRoot, root10);
        uint256[8] memory proof;
        proof[0] = 1;
        vm.chainId(CHAIN_ZERO);
        vm.prank(proposer);
        deployedManager0.applyBridgeWindow(proof, deposits, proof, windowFinalizationOpening);
        assertEq(deployedManager0.lastFinalizedCheckpointId(), 10);
        assertEq(deployedManager0.lastVerifiedCheckpointRoot(), root10);
        vm.chainId(CHAIN_ONE);
        vm.prank(proposer);
        deployedManager1.applyBridgeWindow(proof, deposits, proof, windowFinalizationOpening);
        assertEq(deployedManager1.lastFinalizedCheckpointId(), 10);
        assertEq(deployedManager1.lastVerifiedCheckpointRoot(), root10);
        assertEq(deployedBridge1.depositRoot(), deployedBridge0.depositRoot());
    }

    function _mixedDeposits(bytes memory config, bytes32 root9, bytes32 root10, bytes32 depositRoot) private pure returns (bytes memory deposits) {
        bytes32 configHash = keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Config"), config));
        bytes memory end = bytes.concat(abi.encode(uint256(10)), _rootWords(root10));
        bytes memory starts = bytes.concat(abi.encode(uint256(2), uint256(0), uint256(9)), _rootWords(root9), abi.encode(uint256(1), uint256(10)), _rootWords(root10));
        bytes memory rows = bytes.concat(abi.encode(uint256(2), uint256(0)), _rootWords(depositRoot), _rootWords(depositRoot), abi.encode(uint256(0), uint256(0)), abi.encode(uint256(1)), _rootWords(depositRoot), _rootWords(depositRoot), abi.encode(uint256(0), uint256(0)));
        bytes32 windowId = keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Window"), configHash, end, starts, rows));
        deposits = bytes.concat(abi.encode(configHash, windowId), end, starts, rows, abi.encode(uint256(0)));
    }

    function _mixedWindowFinalization(bytes memory deposits, bytes32 historicalRoot, bytes32 depositRoot) private pure returns (bytes memory) {
        bytes memory header = new bytes(224);
        for (uint256 i; i < 224; ++i) header[i] = deposits[i];
        return bytes.concat(header, _u32x8(bytes32(0)), _u32x8(bytes32(0)), abi.encode(uint256(2)), _rootWords(historicalRoot), abi.encode(uint256(1)), _rootWords(historicalRoot), abi.encode(uint256(1)), abi.encode(uint256(2)), _rootWords(depositRoot), abi.encode(uint256(0)), _rootWords(bytes32(0)), _rootWords(depositRoot), abi.encode(uint256(0)), _rootWords(bytes32(0)), abi.encode(uint256(0)), _rootWords(bytes32(0)), _rootWords(bytes32(0)), abi.encode(bytes32(0), uint256(0)));
    }
}
