// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../../src/Bridge.sol";
import {BridgeOpening} from "../../../src/BridgeOpening.sol";
import {StateManager} from "../../../src/StateManager.sol";
import {Router} from "../../../src/Router.sol";
import {PsyAddressesProvider} from "../../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../../src/PsyACLManager.sol";
import {MockGnarkVerifier} from "./MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "./TestERC1967Proxy.sol";

// Mock proofs exercise orchestration only, never cryptographic acceptance.
abstract contract AtomicBridgeFixture is Test {
    bytes32 internal constant EMPTY_DEPOSIT_ROOT =
        0xe479b9bb36c3fc43b1e4dac93c0cde8e29332a714327ba72d65af5933a094e83;
    Bridge internal atomicBridge;
    StateManager internal manager;
    PsyAddressesProvider internal provider;
    bytes internal networkConfig;
    MockGnarkVerifier internal finalizeVerifier;
    MockGnarkVerifier internal depositVerifier;
    MockGnarkVerifier internal withdrawalVerifier;
    MockGnarkVerifier internal rewardVerifier;

    struct Window {
        uint256[8] finalizeProof;
        uint256[] inputs;
        uint256[8] depositProof;
        bytes deposits;
        uint256[8] withdrawalProof;
        bytes withdrawals;
        uint256[8] rewardProof;
        bytes rewards;
    }

    function _deployAtomic(address owner, address proposer) internal {
        provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(new PsyAddressesProvider()), abi.encodeCall(PsyAddressesProvider.initialize, (owner)))));
        PsyACLManager acl = PsyACLManager(address(new TestERC1967Proxy(address(new PsyACLManager()), abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, proposer)))));
        finalizeVerifier = new MockGnarkVerifier();
        depositVerifier = new MockGnarkVerifier();
        withdrawalVerifier = new MockGnarkVerifier();
        rewardVerifier = new MockGnarkVerifier();
        Bridge bridgeImpl = new Bridge();
        StateManager managerImpl = new StateManager();
        Router router = Router(address(new TestERC1967Proxy(address(new Router()), abi.encodeCall(Router.initialize, (owner, address(provider))))));
        address bridgeProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address managerProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.BRIDGE_ID(), bridgeProxy);
        provider.setAddress(provider.STATE_MANAGER_ID(), managerProxy);
        provider.setAddress(provider.ERC20_GATEWAY_ID(), owner);
        provider.setAddress(provider.ROUTER_ID(), address(router));
        vm.stopPrank();
        networkConfig = bytes.concat(
            abi.encode(uint32(1), uint64(42), uint32(524288), bytes32(uint256(7)), uint256(1)),
            abi.encode(uint8(0), block.chainid, bridgeProxy, managerProxy, uint64(0)), _rootWords(bytes32(0)),
            abi.encode(uint8(0), address(13), address(14), uint256(1), uint8(18), uint64(0), uint64(1000), uint32(1024), uint32(1024), uint32(1024))
        );
        atomicBridge = Bridge(payable(address(new TestERC1967Proxy(address(bridgeImpl), abi.encodeCall(Bridge.initialize, (owner, address(provider), networkConfig, uint8(0)))))));
        manager = StateManager(address(new TestERC1967Proxy(address(managerImpl), abi.encodeCall(StateManager.initialize, (owner, address(provider), uint8(0), networkConfig, address(finalizeVerifier), address(depositVerifier), address(withdrawalVerifier), address(rewardVerifier))))));
    }

    function _rootWords(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }

    function _window(uint64 endId, bytes32 endRoot, BridgeOpening.DepositTransition memory transition, BridgeOpening.DepositLeaf[] memory leaves, BridgeOpening.WithdrawalLeaf[] memory withdrawals) internal view returns (Window memory w) {
        bytes memory end = bytes.concat(abi.encode(endId), _rootWords(endRoot));
        bytes memory starts = bytes.concat(abi.encode(uint256(1), uint8(0), manager.lastFinalizedCheckpointId()), _rootWords(manager.lastVerifiedCheckpointRoot()));
        bytes memory deposits = bytes.concat(abi.encode(uint256(1), transition.chainIndex), _rootWords(transition.oldRoot), _rootWords(transition.newRoot), abi.encode(transition.oldCount, transition.newCount));
        bytes32 configHash = atomicBridge.configHash();
        bytes32 windowId = keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Window"), configHash, end, starts, deposits));
        bytes memory context = bytes.concat(abi.encode(configHash, windowId), end);
        w.deposits = bytes.concat(context, starts, deposits, abi.encode(leaves.length));
        for (uint256 i; i < leaves.length; ++i) w.deposits = bytes.concat(w.deposits, abi.encode(leaves[i]));
        w.withdrawals = bytes.concat(context, abi.encode(uint256(1)), _rootWords(bytes32(0)), abi.encode(withdrawals.length));
        for (uint256 i; i < withdrawals.length; ++i) w.withdrawals = bytes.concat(w.withdrawals, abi.encode(withdrawals[i]));
        w.rewards = bytes.concat(context, abi.encode(uint256(0)));
        w.depositProof[0] = 1;
        if (withdrawals.length != 0) w.withdrawalProof[0] = 1;
        w.inputs = new uint256[](35);
        w.finalizeProof[0] = 1;
        for (uint256 i; i < 4; ++i) {
            w.inputs[i] = uint64(uint256(manager.lastVerifiedCheckpointRoot()) >> ((3 - i) * 64));
            w.inputs[20 + i] = uint64(uint256(endRoot) >> ((3 - i) * 64));
            w.inputs[26 + i] = uint64(uint256(transition.newRoot) >> ((3 - i) * 64));
        }
        w.inputs[24] = endId;
        w.inputs[25] = endId - manager.lastFinalizedCheckpointId();
        w.inputs[30] = transition.newCount;
    }

    function _emptyWindow(uint64 endId, bytes32 endRoot) internal view returns (Window memory) {
        return _window(endId, endRoot, BridgeOpening.DepositTransition(0, atomicBridge.depositRoot(), atomicBridge.depositRoot(), uint32(atomicBridge.provedDepositCount()), uint32(atomicBridge.provedDepositCount())), new BridgeOpening.DepositLeaf[](0), new BridgeOpening.WithdrawalLeaf[](0));
    }

    function _withdrawalWindow(address recipient, address token, uint256 amount, bytes32 nonce) internal view returns (Window memory) {
        BridgeOpening.WithdrawalLeaf[] memory leaves = new BridgeOpening.WithdrawalLeaf[](1);
        leaves[0] = BridgeOpening.WithdrawalLeaf(0, 0, recipient, token, amount, nonce);
        return _window(manager.lastFinalizedCheckpointId() + 1, bytes32(uint256(manager.lastFinalizedCheckpointId() + 1)), BridgeOpening.DepositTransition(0, atomicBridge.depositRoot(), atomicBridge.depositRoot(), uint32(atomicBridge.provedDepositCount()), uint32(atomicBridge.provedDepositCount())), new BridgeOpening.DepositLeaf[](0), leaves);
    }

    function _apply(Window memory w) internal {
        manager.applyBridgeWindow(w.finalizeProof, w.inputs, w.depositProof, w.deposits, w.withdrawalProof, w.withdrawals, w.rewardProof, w.rewards);
    }
}
