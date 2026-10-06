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
        uint256[8] depositProof;
        bytes deposits;
        uint256[8] settlementProof;
        bytes settlement;
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
        uint64 startId = manager.lastFinalizedCheckpointId();
        w.settlement = bytes.concat(context, _u32x8(bytes32(0)), _u32x8(bytes32(0)), abi.encode(uint256(1)), _rootWords(manager.lastVerifiedCheckpointRoot()), abi.encode(endId > startId ? uint256(endId - startId) : uint256(1)), abi.encode(uint256(1)), _rootWords(transition.newRoot), abi.encode(uint256(transition.newCount)), _rootWords(bytes32(0)), abi.encode(withdrawals.length));
        for (uint256 i; i < withdrawals.length; ++i) w.settlement = bytes.concat(w.settlement, abi.encode(withdrawals[i]));
        w.settlement = bytes.concat(w.settlement, _rootWords(bytes32(0)), _rootWords(bytes32(0)), abi.encode(bytes32(0), uint256(0)));
        w.depositProof[0] = 1;
        w.settlementProof[0] = 1;
    }

    function _u32x8(bytes32 packed) internal pure returns (bytes memory) {
        uint256 value = uint256(packed);
        uint256 mask = type(uint32).max;
        return abi.encode((value >> 224) & mask, (value >> 192) & mask, (value >> 160) & mask, (value >> 128) & mask, (value >> 96) & mask, (value >> 64) & mask, (value >> 32) & mask, value & mask);
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
        manager.applyBridgeWindow(w.depositProof, w.deposits, w.settlementProof, w.settlement);
    }

    function _claimWindow(Window memory w, uint256 ordinal) internal {
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(networkConfig);
        BridgeOpening.DepositAggregateOpening memory deposit = BridgeOpening.readDepositAggregate(w.deposits, config);
        BridgeOpening.SettlementOpening memory settlement = BridgeOpening.readSettlementOpening(w.settlement, config, deposit.depositOpeningDigest);
        bytes memory header = BridgeOpening.withdrawalPublicationHeader(settlement);
        atomicBridge.claimAggregateWithdrawal(BridgeOpening.inclusionHeaderDigest(header), uint32(ordinal), abi.encode(settlement.withdrawals[ordinal]), _claimSiblings(settlement.withdrawals, ordinal));
    }

    function _claimSiblings(BridgeOpening.WithdrawalLeaf[] memory leaves, uint256 ordinal) internal pure returns (bytes32[] memory path) {
        uint256 capacity = 1024;
        bytes32[] memory layer = new bytes32[](capacity);
        uint256 count = leaves.length;
        for (uint256 i; i < capacity; ++i) {
            layer[i] = i < count
                ? keccak256(abi.encodePacked(BridgeOpening.LEAF, bytes32(uint256(12)), bytes32(count), bytes32(i), BridgeOpening.withdrawalLeafCommit(abi.encode(leaves[i]))))
                : keccak256(abi.encodePacked(BridgeOpening.EMPTY, bytes32(uint256(12)), bytes32(count), bytes32(i)));
        }
        path = new bytes32[](10);
        uint256 index = ordinal;
        for (uint256 level; level < 10; ++level) {
            path[level] = layer[index ^ 1];
            uint256 parentCount = capacity >> 1;
            for (uint256 i; i < parentCount; ++i) {
                layer[i] = keccak256(abi.encodePacked(BridgeOpening.NODE, bytes32(uint256(12)), bytes32(level + 1), layer[2 * i], layer[2 * i + 1]));
            }
            capacity = parentCount;
            index >>= 1;
        }
    }
}
