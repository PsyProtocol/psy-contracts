// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {StateManager} from "../../src/StateManager.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

// Orchestration only: this verifier does not establish cryptographic validity.
contract AdmissionVerifier {
    bool public reject;
    bytes32 public expected;
    error RejectedProof();
    function setReject(bool value) external { reject = value; }
    function setExpected(bytes32 value) external { expected = value; }
    function endpointChainListHash() external pure returns (bytes32) {
        return keccak256(abi.encodePacked("PsyBridge/FinalizeChainList/1", uint16(1), uint8(1)));
    }
    function verifyProof(uint256[8] calldata, uint256[2] calldata inputs) external view {
        if (reject || (expected != bytes32(0) && expected != bytes32((inputs[0] << 128) | inputs[1]))) revert RejectedProof();
    }
}

contract RejectAdmissionRewardPayer {
    bytes32 public configHash;
    address public stateManager;
    uint256 public ethereumChainId = block.chainid;
    error RewardFailure();
    function configure(bytes32 hash, address manager) external { configHash = hash; stateManager = manager; }
    function payRewards(BridgeOpening.RewardLeaf[] calldata) external pure { revert RewardFailure(); }
}

contract BridgeAggregateAdmissionTest is Test {
    Bridge private bridge;
    StateManager private manager;
    AdmissionVerifier private finalizeVerifier;
    AdmissionVerifier private depositVerifier;
    AdmissionVerifier private withdrawalVerifier;
    AdmissionVerifier private rewardVerifier;
    RejectAdmissionRewardPayer private payer;
    bytes private config;
    bytes32 private constant EMPTY_ROOT = 0xe479b9bb36c3fc43b1e4dac93c0cde8e29332a714327ba72d65af5933a094e83;
    uint64 private currentId;
    bytes32 private currentRoot;

    function domain(string memory label) private pure returns (bytes32) {
        return keccak256(bytes.concat(bytes("PsyBridge/TwoArtifact/1/"), bytes(label)));
    }
    function rootWords(bytes32 root) private pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }
    function setUp() public {
        PsyAddressesProvider provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(new PsyAddressesProvider()), abi.encodeCall(PsyAddressesProvider.initialize, (address(this))))));
        PsyACLManager acl = PsyACLManager(address(new TestERC1967Proxy(address(new PsyACLManager()), abi.encodeCall(PsyACLManager.initialize, (address(this), address(this), address(this), address(this), address(this))))));
        payer = new RejectAdmissionRewardPayer();
        Bridge bridgeImpl = new Bridge();
        StateManager managerImpl = new StateManager();
        finalizeVerifier = new AdmissionVerifier();
        depositVerifier = new AdmissionVerifier();
        withdrawalVerifier = new AdmissionVerifier();
        rewardVerifier = new AdmissionVerifier();
        address bridgeProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address managerProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        provider.setAddress(provider.BRIDGE_ID(), bridgeProxy);
        provider.setAddress(provider.STATE_MANAGER_ID(), managerProxy);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        config = bytes.concat(
            abi.encode(uint256(1), uint256(0), uint256(524288), bytes32(uint256(7)), uint256(1)),
            abi.encode(uint256(1), block.chainid, bridgeProxy, managerProxy, uint256(0)), rootWords(bytes32(0)),
            abi.encode(uint256(1), address(payer), address(14), uint256(1), uint256(18), uint256(0), uint256(100), uint256(1024), uint256(1024), uint256(1024))
        );
        bridge = Bridge(payable(address(new TestERC1967Proxy(address(bridgeImpl), abi.encodeCall(Bridge.initialize, (address(this), address(provider), config, uint8(1)))))));
        manager = StateManager(address(new TestERC1967Proxy(address(managerImpl), abi.encodeCall(StateManager.initialize, (address(this), address(provider), uint8(1), config, address(finalizeVerifier), address(depositVerifier), address(withdrawalVerifier), address(rewardVerifier))))));
        payer.configure(manager.configHash(), address(manager));
        address[] memory tokens = new address[](1);
        Bridge.TokenFlowConfig[] memory limits = new Bridge.TokenFlowConfig[](1);
        limits[0] = Bridge.TokenFlowConfig(1, 1000, 100, 200, 1000, 0, 0, 0, true);
        bridge.initializeFlowLimits(tokens, limits);
    }
    function depositOpening(uint64 endId, bytes32 endRoot) private view returns (bytes memory) {
        bytes32 hash = keccak256(bytes.concat(domain("Config"), config));
        bytes memory end = bytes.concat(abi.encode(endId), rootWords(endRoot));
        bytes memory starts = bytes.concat(abi.encode(uint256(1), uint256(1), currentId), rootWords(currentRoot));
        bytes memory deposits = bytes.concat(abi.encode(uint256(1), uint256(1)), rootWords(EMPTY_ROOT), rootWords(EMPTY_ROOT), abi.encode(uint256(0), uint256(0)));
        bytes32 windowId = keccak256(bytes.concat(domain("Window"), hash, end, starts, deposits));
        return bytes.concat(abi.encode(hash, windowId), end, starts, deposits, abi.encode(uint256(0)));
    }
    function aggregate(bytes memory a, bytes memory records) private pure returns (bytes memory) {
        bytes memory header = new bytes(224);
        for (uint256 i; i < 224; ++i) header[i] = a[i];
        return bytes.concat(header, records);
    }
    function withdrawalAggregate(bytes memory a, bytes memory records) private pure returns (bytes memory) {
        return aggregate(a, bytes.concat(abi.encode(uint256(1)), rootWords(EMPTY_ROOT), records));
    }
    function finalizeInputs() private pure returns (uint256[] memory pi) {
        pi = new uint256[](35);
        pi[23] = 1; pi[24] = 1; pi[25] = 1;
        for (uint256 i; i < 4; ++i) {
            pi[26 + i] = uint64(uint256(EMPTY_ROOT) >> (192 - i * 64));
            pi[31 + i] = pi[26 + i];
        }
    }
    function proof() private pure returns (uint256[8] memory p) { p[0] = 1; }
    function withdrawal() private pure returns (bytes memory) {
        return abi.encode(uint256(1), uint256(1), uint256(7), address(15), address(0), uint256(1), bytes32(uint256(4)));
    }
    function reward() private pure returns (bytes memory) {
        return abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(0), uint256(3), address(15));
    }
    function applyWindow(bytes memory withdrawals, bytes memory rewards, bool hasW, bool hasR) private {
        uint256[8] memory zero;
        bytes memory a = depositOpening(1, bytes32(uint256(1)));
        manager.applyBridgeWindow(proof(), finalizeInputs(), proof(), a, hasW ? proof() : zero, withdrawalAggregate(a, withdrawals), hasR ? proof() : zero, aggregate(a, rewards));
        currentId = 1;
        currentRoot = bytes32(uint256(1));
    }
    function applyEmpty(uint256[] memory pi, uint256[8] memory finalizeProof) private {
        uint256[8] memory zero;
        bytes memory a = depositOpening(uint64(pi[24]), bytes32((pi[20] << 192) | (pi[21] << 128) | (pi[22] << 64) | pi[23]));
        manager.applyBridgeWindow(finalizeProof, pi, proof(), a, zero, withdrawalAggregate(a, abi.encode(uint256(0))), zero, aggregate(a, abi.encode(uint256(0))));
    }
    function testDepositEffectRequiresManager() public {
        vm.expectRevert(Bridge.OnlyStateManager.selector);
        bridge.applyDepositAggregate(depositOpening(1, bytes32(uint256(1))));
    }
    function testReplayStillVerifiesDepositProof() public {
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
        depositVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }
    function testReplayAcceptsHistoricalStartAndSkipsEmptyFamilyVerifiers() public {
        withdrawalVerifier.setReject(true);
        rewardVerifier.setReject(true);
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(1)));
        assertEq(bridge.depositRoot(), EMPTY_ROOT);
    }
    function testReplayCannotOmitFinalizeVerification() public {
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
        finalizeVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
    }
    function testWithdrawalVerifierReceivesFlatStatementHalves() public {
        bytes memory opening = withdrawalAggregate(depositOpening(1, bytes32(uint256(1))), withdrawal());
        withdrawalVerifier.setExpected(keccak256(abi.encodePacked(domain("WithdrawalBatch"), opening)));
        applyWindow(withdrawal(), abi.encode(uint256(0)), true, false);
        assertTrue(bridge.claimedNullifiers(bytes32(uint256(4))));
    }
    function testRewardVerifierReceivesFlatStatementBeforePayout() public {
        bytes memory opening = aggregate(depositOpening(1, bytes32(uint256(1))), reward());
        rewardVerifier.setExpected(keccak256(abi.encodePacked(domain("RewardBatch"), opening)));
        vm.expectRevert(RejectAdmissionRewardPayer.RewardFailure.selector);
        applyWindow(abi.encode(uint256(0)), reward(), false, true);
    }
    function testWithdrawalReplayReverts() public {
        applyWindow(withdrawal(), abi.encode(uint256(0)), true, false);
        assertTrue(bridge.claimedNullifiers(bytes32(uint256(4))));
        vm.expectRevert(Bridge.NullifierAlreadyClaimed.selector);
        applyWindow(withdrawal(), abi.encode(uint256(0)), true, false);
    }
    function testRewardFailureRollsBackWithdrawalAndAdvance() public {
        vm.expectRevert(RejectAdmissionRewardPayer.RewardFailure.selector);
        applyWindow(withdrawal(), reward(), true, true);
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(4))));
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertEq(manager.depositSubtreeRoot(), bytes32(0));
        (, , uint256 amount,) = bridge.pendingWithdrawals(bytes32(uint256(4)));
        assertEq(amount, 0);
    }
    function testLaterProofFailureHasNoEffects() public {
        rewardVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyWindow(withdrawal(), reward(), true, true);
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(4))));
    }
    function testFinalizeHashesLegacy144BytesAndEndpoint72Bytes() public {
        uint256[] memory pi = finalizeInputs();
        for (uint256 i = 4; i < 20; ++i) pi[i] = i + 1;
        pi[20] = 1; pi[21] = 2; pi[22] = 3; pi[23] = 4;
        bytes memory encoded = abi.encodePacked(uint64(0), uint64(0), uint64(0), uint64(0));
        for (uint256 i = 4; i < 20; i += 2) encoded = bytes.concat(encoded, abi.encodePacked(uint32(pi[i + 1]), uint32(pi[i])));
        encoded = bytes.concat(encoded, abi.encodePacked(uint64(1), uint64(2), uint64(3), uint64(4), uint64(1), uint64(1)));
        for (uint256 i = 26; i < 35; ++i) encoded = bytes.concat(encoded, abi.encodePacked(uint64(pi[i])));
        finalizeVerifier.setExpected(keccak256(encoded));
        applyEmpty(pi, proof());
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertEq(manager.depositSubtreeRoot(), EMPTY_ROOT);
        assertEq(manager.lastVerifiedDepositTreeRoot(), bytes32(abi.encodePacked(uint32(5), uint32(6), uint32(7), uint32(8), uint32(9), uint32(10), uint32(11), uint32(12))));
    }
    function testBootstrapIdentityFailsClosed() public {
        uint256[] memory pi = new uint256[](35);
        uint256[8] memory zero;
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        applyEmpty(pi, zero);
    }
    function testPositiveFinalizeRejectsZeroProof() public {
        uint256[8] memory zero;
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyEmpty(finalizeInputs(), zero);
    }
    function testRejectsNonzeroEmptyFamilyProof() public {
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), true, false);
    }
    function testRejectsOmittedNonemptyProof() public {
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyWindow(withdrawal(), abi.encode(uint256(0)), false, false);
    }
    function testRejectsMismatchedWindow() public {
        bytes memory a = depositOpening(1, bytes32(uint256(1)));
        bytes memory w = withdrawalAggregate(a, abi.encode(uint256(0)));
        assembly ("memory-safe") { mstore(add(w, 64), 99) }
        uint256[8] memory zero;
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        manager.applyBridgeWindow(proof(), finalizeInputs(), proof(), a, zero, w, zero, aggregate(a, abi.encode(uint256(0))));
    }
    function testProviderProposerAclStillRequired() public {
        vm.prank(address(99));
        vm.expectRevert(StateManager.OnlyProposer.selector);
        applyWindow(abi.encode(uint256(0)), abi.encode(uint256(0)), false, false);
    }
    function testFinalizeFailureLeavesCursorUnchanged() public {
        finalizeVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyEmpty(finalizeInputs(), proof());
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }
    function testRejectsFinalizeWrongSpan() public {
        uint256[] memory pi = finalizeInputs();
        pi[25] = 2;
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsFinalizeSlotOverflow() public {
        uint256[] memory pi = finalizeInputs();
        pi[4] = uint256(1) << 32;
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsWrongFinalizeLength() public {
        uint256[] memory pi = new uint256[](26);
        pi[23] = 1; pi[24] = 1; pi[25] = 1;
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsDepositEndpointRootSubstitution() public {
        uint256[] memory pi = finalizeInputs();
        pi[26] = 1;
        vm.expectRevert(StateManager.InvalidDepositMerkleProof.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsDepositEndpointCountSubstitution() public {
        uint256[] memory pi = finalizeInputs();
        pi[30] = 1;
        vm.expectRevert(StateManager.InvalidDepositMerkleProof.selector);
        applyEmpty(pi, proof());
    }
    function testEmptyWithdrawalStillBindsEndpointRoot() public {
        uint256[] memory pi = finalizeInputs();
        pi[31] = 1;
        vm.expectRevert(StateManager.InvalidWithdrawalMerkleProof.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsNoncanonicalEndpointRoot() public {
        uint256[] memory pi = finalizeInputs();
        pi[31] = 18446744069414584321;
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyEmpty(pi, proof());
    }
    function testInitializationRejectsWrongVerifierChainList() public {
        StateManager impl = new StateManager();
        vm.mockCall(address(finalizeVerifier), abi.encodeWithSelector(AdmissionVerifier.endpointChainListHash.selector), abi.encode(bytes32(uint256(99))));
        vm.expectRevert(StateManager.InvalidProvenChainIndex.selector);
        new TestERC1967Proxy(address(impl), abi.encodeCall(StateManager.initialize, (address(this), address(1), uint8(1), config, address(finalizeVerifier), address(depositVerifier), address(withdrawalVerifier), address(rewardVerifier))));
    }
}

// Test-only verifier: metadata models the fixed sparse constructor list, not a real VK.
contract SparseAdmissionVerifier {
    function endpointChainListHash() external pure returns (bytes32) {
        return keccak256(abi.encodePacked("PsyBridge/FinalizeChainList/1", uint16(2), uint8(0), uint8(3)));
    }
    function verifyProof(uint256[8] calldata, uint256[2] calldata) external pure {}
}

contract SparseEndpointAdmissionTest is Test {
    Bridge private bridge;
    StateManager private manager;
    bytes private config;
    bytes32 private constant EMPTY_ROOT = 0xe479b9bb36c3fc43b1e4dac93c0cde8e29332a714327ba72d65af5933a094e83;

    function rootWords(bytes32 root) private pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }
    function setUp() public {
        PsyAddressesProvider provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(new PsyAddressesProvider()), abi.encodeCall(PsyAddressesProvider.initialize, (address(this))))));
        PsyACLManager acl = PsyACLManager(address(new TestERC1967Proxy(address(new PsyACLManager()), abi.encodeCall(PsyACLManager.initialize, (address(this), address(this), address(this), address(this), address(this))))));
        Bridge bridgeImpl = new Bridge();
        StateManager managerImpl = new StateManager();
        SparseAdmissionVerifier verifier = new SparseAdmissionVerifier();
        address bridgeProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address managerProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        provider.setAddress(provider.BRIDGE_ID(), bridgeProxy);
        provider.setAddress(provider.STATE_MANAGER_ID(), managerProxy);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        config = bytes.concat(
            abi.encode(uint256(1), uint256(0), uint256(524288), bytes32(uint256(7)), uint256(2)),
            abi.encode(uint256(0), block.chainid, bridgeProxy, managerProxy, uint256(0)), rootWords(bytes32(0)),
            abi.encode(uint256(3), block.chainid + 1, address(31), address(32), uint256(0)), rootWords(bytes32(0)),
            abi.encode(uint256(0), address(13), address(14), uint256(1), uint256(18), uint256(0), uint256(100), uint256(1024), uint256(1024), uint256(1024))
        );
        bridge = Bridge(payable(address(new TestERC1967Proxy(address(bridgeImpl), abi.encodeCall(Bridge.initialize, (address(this), address(provider), config, uint8(0)))))));
        manager = StateManager(address(new TestERC1967Proxy(address(managerImpl), abi.encodeCall(StateManager.initialize, (address(this), address(provider), uint8(0), config, address(verifier), address(verifier), address(verifier), address(verifier))))));
    }
    function applySparse(bool replay, uint256 mutation) private {
        bytes32 hash = keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Config"), config));
        bytes memory end = bytes.concat(abi.encode(uint256(1)), rootWords(bytes32(uint256(1))));
        uint256 start = replay ? 1 : 0;
        bytes memory starts = bytes.concat(abi.encode(uint256(2), uint256(0), start), rootWords(bytes32(start)), abi.encode(uint256(3), start), rootWords(bytes32(start)));
        bytes32 foreignDepositRoot = bytes32(uint256(mutation == 1 ? 7 : 5));
        uint256 foreignCount = mutation == 2 ? 1 : 0;
        bytes memory deposits = bytes.concat(
            abi.encode(uint256(2), uint256(0)), rootWords(EMPTY_ROOT), rootWords(EMPTY_ROOT), abi.encode(uint256(0), uint256(0), uint256(3)),
            rootWords(foreignDepositRoot), rootWords(foreignDepositRoot), abi.encode(foreignCount, foreignCount)
        );
        bytes32 windowId = keccak256(bytes.concat(keccak256("PsyBridge/TwoArtifact/1/Window"), hash, end, starts, deposits));
        bytes memory context = bytes.concat(abi.encode(hash, windowId), end);
        bytes memory deposit = bytes.concat(context, starts, deposits, abi.encode(uint256(0)));
        bytes memory withdrawal = bytes.concat(context, abi.encode(uint256(2)), rootWords(EMPTY_ROOT), rootWords(bytes32(uint256(mutation == 3 ? 7 : 6))), abi.encode(uint256(0)));
        uint256[] memory pi = new uint256[](44);
        pi[23] = 1; pi[24] = 1; pi[25] = 1;
        for (uint256 i; i < 4; ++i) {
            pi[26 + i] = uint64(uint256(EMPTY_ROOT) >> (192 - i * 64));
            pi[31 + i] = pi[26 + i];
        }
        pi[38] = 5;
        pi[43] = 6;
        uint256[8] memory proof;
        proof[0] = 1;
        uint256[8] memory zero;
        manager.applyBridgeWindow(proof, pi, proof, deposit, zero, withdrawal, zero, bytes.concat(context, abi.encode(uint256(0))));
    }
    function rejectNonlocalMutation(bool replay, uint256 mutation, bytes4 errorSelector) private {
        if (replay) applySparse(false, 0);
        vm.expectRevert(errorSelector);
        applySparse(replay, mutation);
        assertEq(manager.lastFinalizedCheckpointId(), replay ? 1 : 0);
        assertEq(bridge.depositRoot(), EMPTY_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
    }
    function testSparseNonlocalDepositRootAdvance() public {
        rejectNonlocalMutation(false, 1, StateManager.InvalidDepositMerkleProof.selector);
    }
    function testSparseNonlocalDepositRootReplay() public {
        rejectNonlocalMutation(true, 1, StateManager.InvalidDepositMerkleProof.selector);
    }
    function testSparseNonlocalDepositCountAdvance() public {
        rejectNonlocalMutation(false, 2, StateManager.InvalidDepositMerkleProof.selector);
    }
    function testSparseNonlocalDepositCountReplay() public {
        rejectNonlocalMutation(true, 2, StateManager.InvalidDepositMerkleProof.selector);
    }
    function testSparseNonlocalWithdrawalRootAdvance() public {
        rejectNonlocalMutation(false, 3, StateManager.InvalidWithdrawalMerkleProof.selector);
    }
    function testSparseNonlocalWithdrawalRootReplay() public {
        rejectNonlocalMutation(true, 3, StateManager.InvalidWithdrawalMerkleProof.selector);
    }
}
