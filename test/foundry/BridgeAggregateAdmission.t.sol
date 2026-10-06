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
    function settlementFrom(bytes memory deposit, bytes memory withdrawalRecords) private view returns (bytes memory) {
        bytes memory header = new bytes(224);
        for (uint256 i; i < 224; ++i) header[i] = deposit[i];
        return bytes.concat(header, abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)), abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)), abi.encode(uint256(1)), rootWords(currentRoot), abi.encode(uint256(1)), abi.encode(uint256(1)), rootWords(EMPTY_ROOT), abi.encode(uint256(0)), rootWords(EMPTY_ROOT), withdrawalRecords, rootWords(bytes32(0)), rootWords(bytes32(0)), abi.encode(bytes32(0), uint256(0)));
    }
    function settlementFromInputs(bytes memory deposit, uint256[] memory pi) private view returns (bytes memory) {
        bytes memory header = new bytes(224);
        for (uint256 i; i < 224; ++i) header[i] = deposit[i];
        return bytes.concat(header, abi.encode(pi[4], pi[5], pi[6], pi[7], pi[8], pi[9], pi[10], pi[11]), abi.encode(pi[12], pi[13], pi[14], pi[15], pi[16], pi[17], pi[18], pi[19]), abi.encode(uint256(1)), rootWords(currentRoot), abi.encode(pi[25]), abi.encode(uint256(1)), abi.encode(pi[26], pi[27], pi[28], pi[29], pi[30]), abi.encode(pi[31], pi[32], pi[33], pi[34]), abi.encode(uint256(0)), rootWords(bytes32(0)), rootWords(bytes32(0)), abi.encode(bytes32(0), uint256(0)));
    }
    function applyWindow(bytes memory withdrawals, uint256[8] memory settlementProof) private {
        bytes memory a = depositOpening(1, bytes32(uint256(1)));
        manager.applyBridgeWindow(proof(), a, settlementProof, settlementFrom(a, withdrawals));
        currentId = 1;
        currentRoot = bytes32(uint256(1));
    }
    function applyEmpty(uint256[] memory pi, uint256[8] memory settlementProof) private {
        if (pi.length < 35) {
            manager.applyBridgeWindow(proof(), depositOpening(1, bytes32(uint256(1))), settlementProof, hex"00");
            return;
        }
        bytes32 endRoot = bytes32((pi[20] << 192) | (pi[21] << 128) | (pi[22] << 64) | pi[23]);
        bytes memory a = depositOpening(uint64(pi[24]), endRoot);
        manager.applyBridgeWindow(proof(), a, settlementProof, settlementFromInputs(a, pi));
    }
    function testDepositEffectRequiresManager() public {
        vm.expectRevert(Bridge.OnlyStateManager.selector);
        bridge.applyDepositAggregate(depositOpening(1, bytes32(uint256(1))));
    }
    function testReplayStillVerifiesDepositProof() public {
        applyWindow(abi.encode(uint256(0)), proof());
        depositVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyWindow(abi.encode(uint256(0)), proof());
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }
    function testEmptyPayoutsIgnoreUnusedVerifierSlots() public {
        withdrawalVerifier.setReject(true);
        rewardVerifier.setReject(true);
        applyWindow(abi.encode(uint256(0)), proof());
        applyWindow(abi.encode(uint256(0)), proof());
        assertEq(manager.lastVerifiedCheckpointRoot(), bytes32(uint256(1)));
        assertEq(bridge.depositRoot(), EMPTY_ROOT);
    }
    function testReplayCannotOmitFinalizeVerification() public {
        applyWindow(abi.encode(uint256(0)), proof());
        finalizeVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyWindow(abi.encode(uint256(0)), proof());
    }
    function testWithdrawalVerifierReceivesFlatStatementHalves() public {
        bytes memory a = depositOpening(1, bytes32(uint256(1)));
        bytes memory settlement = settlementFrom(a, withdrawal());
        BridgeOpening.NetworkConfig memory cfg = BridgeOpening.readConfig(config);
        finalizeVerifier.setExpected(BridgeOpening.readSettlementOpening(settlement, cfg, BridgeOpening.readDepositAggregate(a, cfg).depositOpeningDigest).openingDigest);
        applyWindow(withdrawal(), proof());
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(4))));
    }
    function testPublicationDoesNotPayRewards() public {
        applyWindow(withdrawal(), proof());
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(4))));
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }
    function testWithdrawalReplayDoesNotConsumeNonce() public {
        applyWindow(withdrawal(), proof());
        applyWindow(withdrawal(), proof());
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(4))));
    }
    function testLaterProofFailureHasNoEffects() public {
        finalizeVerifier.setReject(true);
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyWindow(withdrawal(), proof());
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(4))));
    }
    function testFinalizeHashesLegacy144BytesAndEndpoint72Bytes() public {
        uint256[] memory pi = finalizeInputs();
        for (uint256 i = 4; i < 20; ++i) pi[i] = i + 1;
        pi[20] = 1; pi[21] = 2; pi[22] = 3; pi[23] = 4;
        bytes32 endRoot = bytes32((pi[20] << 192) | (pi[21] << 128) | (pi[22] << 64) | pi[23]);
        bytes memory a = depositOpening(uint64(pi[24]), endRoot);
        bytes memory settlement = settlementFromInputs(a, pi);
        BridgeOpening.NetworkConfig memory cfg = BridgeOpening.readConfig(config);
        finalizeVerifier.setExpected(BridgeOpening.readSettlementOpening(settlement, cfg, BridgeOpening.readDepositAggregate(a, cfg).depositOpeningDigest).openingDigest);
        applyEmpty(pi, proof());
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertEq(manager.depositSubtreeRoot(), EMPTY_ROOT);
        assertEq(manager.lastVerifiedDepositTreeRoot(), bytes32(abi.encodePacked(uint32(5), uint32(6), uint32(7), uint32(8), uint32(9), uint32(10), uint32(11), uint32(12))));
    }
    function testBootstrapIdentityFailsClosed() public {
        uint256[] memory pi = new uint256[](35);
        uint256[8] memory zero;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        applyEmpty(pi, zero);
    }
    function testPositiveFinalizeRejectsZeroProof() public {
        uint256[8] memory zero;
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyEmpty(finalizeInputs(), zero);
    }
    function testRejectsOmittedNonemptyProof() public {
        uint256[8] memory zero;
        vm.expectRevert(StateManager.InvalidProof.selector);
        applyWindow(withdrawal(), zero);
    }
    function testRejectsMismatchedWindow() public {
        bytes memory a = depositOpening(1, bytes32(uint256(1)));
        bytes memory settlement = settlementFrom(a, abi.encode(uint256(0)));
        assembly ("memory-safe") { mstore(add(settlement, 64), 99) }
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        manager.applyBridgeWindow(proof(), a, proof(), settlement);
    }
    function testProviderProposerAclStillRequired() public {
        vm.prank(address(99));
        vm.expectRevert(StateManager.OnlyProposer.selector);
        applyWindow(abi.encode(uint256(0)), proof());
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
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsWrongFinalizeLength() public {
        uint256[] memory pi = new uint256[](26);
        pi[23] = 1; pi[24] = 1; pi[25] = 1;
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
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
        bytes32 endRoot = bytes32((pi[20] << 192) | (pi[21] << 128) | (pi[22] << 64) | pi[23]);
        bytes memory a = depositOpening(uint64(pi[24]), endRoot);
        bytes memory settlement = settlementFromInputs(a, pi);
        BridgeOpening.NetworkConfig memory cfg = BridgeOpening.readConfig(config);
        finalizeVerifier.setExpected(BridgeOpening.readSettlementOpening(settlement, cfg, BridgeOpening.readDepositAggregate(a, cfg).depositOpeningDigest).openingDigest);
        pi[31] = 1;
        vm.expectRevert(AdmissionVerifier.RejectedProof.selector);
        applyEmpty(pi, proof());
    }
    function testRejectsNoncanonicalEndpointRoot() public {
        uint256[] memory pi = finalizeInputs();
        pi[31] = 18446744069414584321;
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
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
        bytes32 settlementForeignRoot = bytes32(uint256(5));
        bytes memory settlement = bytes.concat(
            context,
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)),
            abi.encode(uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)),
            abi.encode(uint256(2)),
            rootWords(bytes32(start)), abi.encode(uint256(1)),
            rootWords(bytes32(start)), abi.encode(uint256(1)),
            abi.encode(uint256(2)),
            rootWords(EMPTY_ROOT), abi.encode(uint256(0)), rootWords(EMPTY_ROOT),
            rootWords(settlementForeignRoot), abi.encode(uint256(0)), rootWords(bytes32(uint256(mutation == 3 ? 7 : 6))),
            abi.encode(uint256(0)),
            rootWords(bytes32(0)), rootWords(bytes32(0)), abi.encode(bytes32(0), uint256(0))
        );
        uint256[8] memory proof;
        proof[0] = 1;
        manager.applyBridgeWindow(proof, deposit, proof, settlement);
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
        applySparse(false, 3);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertEq(bridge.depositRoot(), EMPTY_ROOT);
    }
    function testSparseNonlocalWithdrawalRootReplay() public {
        applySparse(false, 0);
        vm.expectRevert(StateManager.InvalidCheckpointContinuity.selector);
        applySparse(true, 3);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertEq(bridge.depositRoot(), EMPTY_ROOT);
    }
}
