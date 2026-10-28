// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {StateManager} from "../../src/StateManager.sol";
import {Router} from "../../src/Router.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {MockERC20} from "../fixtures/contracts/MockERC20.sol";
import {MockGnarkVerifier} from "../fixtures/contracts/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

contract DepositBatchHashVerifier {
    bytes32 internal immutable expectedHash;

    constructor(bytes32 expectedHash_) {
        expectedHash = expectedHash_;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata pubs) external view {
        bytes32 actualHash = bytes32((uint256(pubs[0]) << 128) | uint256(pubs[1]));
        require(actualHash == expectedHash, "unexpected hash");
    }
}

contract WithdrawalBatchHashVerifier {
    bytes32 internal immutable expectedHash;

    constructor(bytes32 expectedHash_) {
        expectedHash = expectedHash_;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata pubs) external view {
        bytes32 actualHash = bytes32((uint256(pubs[0]) << 128) | uint256(pubs[1]));
        require(actualHash == expectedHash, "unexpected hash");
    }
}

contract RevertingTransferToken is MockERC20 {
    constructor() MockERC20("Revert", "RVT") {}

    function transfer(address, uint256) public pure override returns (bool) {
        revert("transfer rejected");
    }
}

contract BridgeTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    bytes32 internal constant EMPTY_DEPOSIT_ROOT =
        0xd65af5933a094e8329332a714327ba72b1e4dac93c0cde8ee479b9bb36c3fc43;
    uint256 internal constant DEPOSIT_BATCH_APPEND_SLOT_WORDS = 41;
    uint256 internal constant DEPOSIT_BATCH_APPEND_SLOT_COUNT = 32;
    uint256 internal constant DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS =
        DEPOSIT_BATCH_APPEND_SLOT_WORDS * DEPOSIT_BATCH_APPEND_SLOT_COUNT;
    uint256 internal constant WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS = 34;
    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    uint32 internal constant BRIDGE_USER_ID = 524288;

    function _deployAddressesProvider() internal returns (PsyAddressesProvider provider) {
        PsyAddressesProvider impl = new PsyAddressesProvider();
        bytes memory initData = abi.encodeCall(PsyAddressesProvider.initialize, (owner));
        provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployACL() internal returns (PsyACLManager acl) {
        PsyACLManager impl = new PsyACLManager();
        bytes memory initData = abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, owner));
        acl = PsyACLManager(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployStateManager(PsyAddressesProvider provider) internal returns (StateManager sm) {
        StateManager impl = new StateManager();
        bytes memory initData = abi.encodeCall(StateManager.initialize, (owner, address(provider), uint8(0)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        sm = StateManager(address(proxy));
    }

    function _deployRouter(PsyAddressesProvider provider) internal returns (Router router) {
        Router impl = new Router();
        bytes memory initData = abi.encodeCall(Router.initialize, (owner, address(provider)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        router = Router(address(proxy));
    }

    function _deployBridge(
        PsyAddressesProvider provider,
        address depositBatchVerifier,
        address withdrawalClaimVerifier
    ) internal returns (Bridge bridge) {
        Bridge impl = new Bridge();
        bytes memory initData = abi.encodeCall(
            Bridge.initialize,
            (owner, address(provider), depositBatchVerifier, withdrawalClaimVerifier)
        );
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        bridge = Bridge(payable(address(proxy)));
    }

    function _defaultFlowConfig() internal pure returns (Bridge.TokenFlowConfig memory) {
        return Bridge.TokenFlowConfig({
            minDepositAmount: 1,
            depositCap: 1e30,
            smallWithdrawalMax: 0,
            mediumWithdrawalMax: 5e18,
            totalWithdrawalCap: 1e24,
            smallWithdrawalDelay: 0,
            mediumWithdrawalDelay: 0,
            largeWithdrawalDelay: 0,
            configured: true
        });
    }

    function _flowConfigs(uint256 length) internal pure returns (Bridge.TokenFlowConfig[] memory configs) {
        configs = new Bridge.TokenFlowConfig[](length);
        for (uint256 i = 0; i < length; ++i) configs[i] = _defaultFlowConfig();
    }

    function _configureFlowToken(Bridge bridge, address token) internal {
        _setFlowConfig(bridge, token, _defaultFlowConfig());
    }

    function _setFlowConfig(Bridge bridge, address token, Bridge.TokenFlowConfig memory config) internal {
        bytes32 expectedConfigHash = bridge.getTokenFlowConfigHash(token);
        vm.prank(owner);
        bridge.setTokenFlowConfig(token, config, expectedConfigHash);
    }

    function _tokenSetHash(address[] memory tokens) internal pure returns (bytes32) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = i; j > 0 && uint160(tokens[j]) < uint160(tokens[j - 1]); --j) {
                (tokens[j - 1], tokens[j]) = (tokens[j], tokens[j - 1]);
            }
        }
        return keccak256(abi.encode(tokens));
    }

    function _setupBridgeSystem() internal returns (Bridge bridge, MockGnarkVerifier verifier) {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        bridge = _deployBridge(provider, address(verifier), address(verifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        provider.setAddress(provider.ERC20_GATEWAY_ID(), owner);
        vm.stopPrank();
        MockERC20 mockToken = new MockERC20("Mock", "MOCK");
        vm.etch(address(0x1234), address(mockToken).code);
        _configureFlowToken(bridge, address(0x1234));
    }

    function _bridgeContractState(
        bytes32 root,
        uint256 provedCount,
        uint256 pendingCount,
        bytes32[32] memory frontier
    ) internal pure returns (Bridge.BridgeContractState memory state_) {
        state_ = Bridge.BridgeContractState({
            depositRoot: root,
            provedDepositCount: provedCount,
            pendingDepositCount: pendingCount,
            depositFrontier: frontier
        });
    }

    function testForceSetStateRestoresFieldsLeavesMappingsAndRetryIsNoOp() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        bytes32 recordedLeaf = bridge.depositLeafHashes(0);
        bytes32 claimedNonce = bytes32(uint256(0xCA11));
        vm.store(address(bridge), keccak256(abi.encode(claimedNonce, uint256(1))), bytes32(uint256(1)));
        assertTrue(bridge.claimedNullifiers(claimedNonce));

        // Seed live non-mapping storage through the legitimate batchAppend path.
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildRecordedDepositSlotDataSingle();
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(0xCAFE)), 0, 1, _computeDepositBatchSlotDataCommit(slotData));
        uint256[8] memory proof;
        vm.prank(owner);
        bridge.batchAppend(proof, publicInputs, slotData);
        assertEq(bridge.depositRoot(), bytes32(uint256(0xCAFE)));
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(bridge.pendingDepositCount(), 1);

        bytes32[32] memory initialFrontier;
        Bridge.BridgeContractState memory expected = _bridgeContractState(bytes32(uint256(0xCAFE)), 1, 1, initialFrontier);
        bytes32[32] memory targetFrontier;
        for (uint256 i = 0; i < targetFrontier.length; ++i) {
            targetFrontier[i] = bytes32(i + 1);
        }
        Bridge.BridgeContractState memory target = _bridgeContractState(bytes32(uint256(0xBEEF)), 0, 0, targetFrontier);

        vm.recordLogs();
        vm.prank(owner);
        bridge.forceSetState(expected, target);
        Vm.Log[] memory resetLogs = vm.getRecordedLogs();
        assertEq(resetLogs.length, 1);
        assertEq(resetLogs[0].topics[0], Bridge.ForceSetState.selector);

        assertEq(bridge.depositRoot(), target.depositRoot);
        assertEq(bridge.provedDepositCount(), target.provedDepositCount);
        assertEq(bridge.pendingDepositCount(), target.pendingDepositCount);
        assertEq(keccak256(abi.encode(bridge.getDepositFrontier())), keccak256(abi.encode(targetFrontier)));
        assertEq(bridge.depositLeafHashes(0), recordedLeaf);
        assertTrue(bridge.claimedNullifiers(claimedNonce));

        vm.recordLogs();
        vm.prank(owner);
        bridge.forceSetState(expected, target);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testForceSetStateFailsClosedOnAuthCasAndInvariants() public {
        (Bridge bridge,) = _setupBridgeSystem();

        bytes32[32] memory frontier;
        Bridge.BridgeContractState memory current = _bridgeContractState(EMPTY_DEPOSIT_ROOT, 0, 0, frontier);

        vm.prank(user);
        vm.expectRevert(Bridge.UnauthorizedBridgeAdmin.selector);
        bridge.forceSetState(current, current);

        Bridge.BridgeContractState memory stale = _bridgeContractState(bytes32(uint256(1)), 0, 0, frontier);
        Bridge.BridgeContractState memory target = _bridgeContractState(bytes32(uint256(2)), 0, 0, frontier);
        vm.prank(owner);
        vm.expectPartialRevert(Bridge.UnexpectedCurrentState.selector);
        bridge.forceSetState(stale, target);

        Bridge.BridgeContractState memory provedAbovePending = _bridgeContractState(bytes32(uint256(2)), 1, 0, frontier);
        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidForceSetState.selector);
        bridge.forceSetState(current, provedAbovePending);

        Bridge.BridgeContractState memory countIncrease = _bridgeContractState(bytes32(uint256(2)), 0, 1, frontier);
        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidForceSetState.selector);
        bridge.forceSetState(current, countIncrease);

        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.pendingDepositCount(), 0);
        assertEq(keccak256(abi.encode(bridge.getDepositFrontier())), keccak256(abi.encode(frontier)));
    }

    function testRecordDepositDisabled() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(verifier), address(verifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        MockERC20 token = new MockERC20("Mock", "MOCK");

        token.mint(user, 1000);

        vm.startPrank(user);
        token.approve(address(bridge), 400);
        vm.expectRevert(Bridge.DirectDepositDisabled.selector);
        bridge.recordDeposit(address(token), 400, bytes32(uint256(123)), bytes32(uint256(456)));
        vm.stopPrank();
    }

    function testRecordDepositFromGatewayRejectsZeroAmount() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(verifier), address(verifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        provider.setAddress(provider.ERC20_GATEWAY_ID(), owner);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(Bridge.ZeroAmount.selector);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 0, bytes32(uint256(123)), bytes32(uint256(456)));
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

    function _dummyGnarkProof() internal pure returns (bytes memory proof) {
        uint256[8] memory proofWords = [uint256(1), 2, 3, 4, 5, 6, 7, 8];
        return abi.encode(proofWords);
    }

    function _bytes32ToWords(bytes32 value) internal pure returns (uint256[] memory out) {
        out = new uint256[](8);
        for (uint256 i = 0; i < 8; ++i) {
            out[i] = uint32(uint256(value >> ((7 - i) * 32)));
        }
    }

    function _bytes32ToWordsLE(bytes32 value) internal pure returns (uint256[] memory out) {
        out = new uint256[](8);
        for (uint256 i = 0; i < 8; ++i) {
            out[i] = uint32(uint256(value >> (i * 32)));
        }
    }

    function _uint256ToWords(uint256 value) internal pure returns (uint256[] memory out) {
        out = _bytes32ToWords(bytes32(value));
    }

    function _buildWithdrawalClaimPublicInputs(
        bytes32 withdrawalRoot,
        bytes32 leafHash,
        address recipient,
        address token,
        uint256 amount,
        bytes32 nonce,
        uint32 destinationChainIndex
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](51);
        uint256[] memory rootWords = _bytes32ToWords(withdrawalRoot);
        uint256[] memory leafWords = _bytes32ToWords(leafHash);
        uint256[] memory recipientWords = _bytes32ToWords(bytes32(uint256(uint160(recipient))));
        uint256[] memory tokenWords = _bytes32ToWords(bytes32(uint256(uint160(token))));
        uint256[] memory amountWords = _uint256ToWords(amount);
        uint256[] memory nonceWords = _bytes32ToWords(nonce);

        for (uint256 i = 0; i < 8; ++i) {
            out[i] = rootWords[i];
            out[8 + i] = leafWords[i];
            out[16 + i] = recipientWords[i];
            out[24 + i] = tokenWords[i];
            out[32 + i] = amountWords[i];
            out[40 + i] = nonceWords[i];
        }
        out[48] = destinationChainIndex;
        out[49] = 0;
        out[50] = 524288;
    }

    function _buildWithdrawalBatchClaimPublicInputsSingle(
        bytes32 withdrawalRoot,
        uint32 senderUserId,
        address recipient,
        address token,
        uint256 amount,
        bytes32 nonce,
        uint32 destinationChainIndex,
        uint32 leafIndex
    ) internal pure returns (uint256[18] memory out, uint256[1088] memory slotData) {
        uint256[] memory rootWords = _bytes32ToWords(withdrawalRoot);
        uint256[] memory recipientWords = _bytes32ToWords(bytes32(uint256(uint160(recipient))));
        uint256[] memory tokenWords = _bytes32ToWords(bytes32(uint256(uint160(token))));
        uint256[] memory amountWords = _uint256ToWords(amount);
        uint256[] memory nonceWords = _bytes32ToWords(nonce);
        for (uint256 i = 0; i < 8; ++i) {
            out[i] = rootWords[i];
        }
        out[8] = 1;
        out[9] = 524288;
        slotData[0] = senderUserId;
        for (uint256 i = 0; i < 8; ++i) {
            slotData[1 + i] = recipientWords[i];
            slotData[9 + i] = tokenWords[i];
            slotData[17 + i] = amountWords[i];
            slotData[25 + i] = nonceWords[i];
        }
        slotData[33] = destinationChainIndex;
        uint256[] memory batchCommitWords = _bytes32ToWords(_computeWithdrawalBatchSlotDataCommit(slotData));
        for (uint256 i = 0; i < 8; ++i) {
            out[10 + i] = batchCommitWords[i];
        }
        leafIndex;
    }

    struct BatchClaimItem {
        uint32 senderUserId;
        address recipient;
        address token;
        uint256 amount;
        bytes32 nonce;
        uint32 destinationChainIndex;
    }

    function _buildWithdrawalBatchClaimMulti(
        bytes32 withdrawalRoot,
        BatchClaimItem[] memory items
    ) internal pure returns (uint256[18] memory out, uint256[1088] memory slotData) {
        uint256[] memory rootWords = _bytes32ToWords(withdrawalRoot);
        for (uint256 i = 0; i < 8; ++i) {
            out[i] = rootWords[i];
        }
        out[8] = items.length;
        out[9] = BRIDGE_USER_ID;
        for (uint256 i = 0; i < items.length; ++i) {
            uint256 slotOffset = i * WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS;
            slotData[slotOffset] = items[i].senderUserId;
            uint256[] memory recipientWords = _bytes32ToWords(bytes32(uint256(uint160(items[i].recipient))));
            uint256[] memory tokenWords = _bytes32ToWords(bytes32(uint256(uint160(items[i].token))));
            uint256[] memory amountWords = _uint256ToWords(items[i].amount);
            uint256[] memory nonceWords = _bytes32ToWords(items[i].nonce);
            for (uint256 j = 0; j < 8; ++j) {
                slotData[slotOffset + 1 + j] = recipientWords[j];
                slotData[slotOffset + 9 + j] = tokenWords[j];
                slotData[slotOffset + 17 + j] = amountWords[j];
                slotData[slotOffset + 25 + j] = nonceWords[j];
            }
            slotData[slotOffset + 33] = items[i].destinationChainIndex;
        }
        _patchBatchCommit(out, slotData);
    }

    function _patchBatchCommit(uint256[18] memory publicInputs, uint256[1088] memory slotData) internal pure {
        uint256[] memory commitWords = _bytes32ToWords(_computeWithdrawalBatchSlotDataCommit(slotData));
        for (uint256 j = 0; j < 8; ++j) {
            publicInputs[10 + j] = commitWords[j];
        }
    }

    function _batchCommitBytes32(uint256[18] memory publicInputs) internal pure returns (bytes32 out) {
        for (uint256 j = 0; j < 8; ++j) {
            out |= bytes32(publicInputs[10 + j] << ((7 - j) * 32));
        }
    }

    function _setupBatchClaimBridge()
        internal
        returns (Bridge bridge, StateManager sm, bytes32 withdrawalRoot)
    {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 root) = _mkTopProof(bytes32(uint256(0x1234)), 0);
        vm.prank(owner);
        sm.finalize(
            _dummyGnarkProof(),
            depositRoot,
            _roots(bytes32(uint256(1)), bytes32(uint256(2))),
            root,
            0,
            1,
            depositProof,
            withdrawalProof
        );
        withdrawalRoot = withdrawalProof[0];
    }

    function _setBatchClaimVerifier(Bridge bridge, uint256[18] memory publicInputs) internal {
        WithdrawalBatchHashVerifier verifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifier));
    }

    function _singleItem(BatchClaimItem memory item)
        internal pure returns (BatchClaimItem[] memory items)
    {
        items = new BatchClaimItem[](1);
        items[0] = item;
    }

    function _computeWithdrawalBatchClaimPublicInputsHash(
        uint256[18] memory pi
    ) internal pure returns (bytes32) {
        bytes memory buf = new bytes((18 / 2) * 8);
        for (uint256 k = 0; k < 18 / 2; ++k) {
            uint64 packed = (uint64(pi[2 * k]) << 32) | uint64(pi[2 * k + 1]);
            uint256 offset = k * 8;
            buf[offset] = bytes1(uint8(packed >> 56));
            buf[offset + 1] = bytes1(uint8(packed >> 48));
            buf[offset + 2] = bytes1(uint8(packed >> 40));
            buf[offset + 3] = bytes1(uint8(packed >> 32));
            buf[offset + 4] = bytes1(uint8(packed >> 24));
            buf[offset + 5] = bytes1(uint8(packed >> 16));
            buf[offset + 6] = bytes1(uint8(packed >> 8));
            buf[offset + 7] = bytes1(uint8(packed));
        }
        return keccak256(buf);
    }

    function _computeWithdrawalBatchSlotDataCommit(
        uint256[1088] memory slotData
    ) internal pure returns (bytes32) {
        bytes memory buf = new bytes(1088 * 4);
        for (uint256 k = 0; k < 1088; ++k) {
            uint256 word = slotData[k];
            uint256 offset = k * 4;
            buf[offset] = bytes1(uint8(word >> 24));
            buf[offset + 1] = bytes1(uint8(word >> 16));
            buf[offset + 2] = bytes1(uint8(word >> 8));
            buf[offset + 3] = bytes1(uint8(word));
        }
        return keccak256(buf);
    }

    function _buildDepositBatchPublicInputs(
        bytes32 oldRoot,
        bytes32 newRoot,
        uint32 fromIndex,
        uint32 toIndex,
        bytes32 batchCommit
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](18 + 32 * 8 + 32 * 16 + 1 + 8);

        uint256[] memory oldRootWords = _bytes32ToWordsLE(oldRoot);
        uint256[] memory newRootWords = _bytes32ToWordsLE(newRoot);
        uint256[] memory batchCommitWords = _bytes32ToWords(batchCommit);

        for (uint256 i = 0; i < 8; ++i) {
            out[i] = oldRootWords[i];
            out[8 + i] = newRootWords[i];
        }
        out[16] = fromIndex;
        out[17] = toIndex;
        uint256 antiForgeryOffset = 18 + 32 * 8 + 32 * 16 + 1;
        for (uint256 i = 0; i < 8; ++i) {
            out[antiForgeryOffset + i] = batchCommitWords[i];
        }
    }

    function _setWord(uint256[] memory arr, uint256 idx, uint256 value) internal pure {
        arr[idx] = value;
    }

    function _computeDepositBatchPublicInputsHash(uint256[] memory pi) internal pure returns (bytes32) {
        bytes memory buf = new bytes(pi.length * 4);
        for (uint256 k = 0; k < pi.length; ++k) {
            uint256 word = pi[k];
            uint256 offset = k * 4;
            buf[offset] = bytes1(uint8(word >> 24));
            buf[offset + 1] = bytes1(uint8(word >> 16));
            buf[offset + 2] = bytes1(uint8(word >> 8));
            buf[offset + 3] = bytes1(uint8(word));
        }
        return keccak256(abi.encodePacked(keccak256(buf)));
    }

    function _computeDepositBatchSlotDataCommit(
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData
    ) internal pure returns (bytes32) {
        bytes memory buf = new bytes(DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS * 4);
        for (uint256 k = 0; k < DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS; ++k) {
            uint256 word = slotData[k];
            uint256 offset = k * 4;
            buf[offset] = bytes1(uint8(word >> 24));
            buf[offset + 1] = bytes1(uint8(word >> 16));
            buf[offset + 2] = bytes1(uint8(word >> 8));
            buf[offset + 3] = bytes1(uint8(word));
        }
        return keccak256(buf);
    }

    function _computeDepositLeafHash(
        bytes32 shieldAddress,
        bytes32 tokenBytes32,
        bytes32 l2TokenContractId,
        uint256 amount,
        uint32 chainIndex,
        bytes32 noteCommitment
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                shieldAddress,
                tokenBytes32,
                l2TokenContractId,
                amount,
                chainIndex,
                noteCommitment
            )
        );
    }

    function _buildDepositBatchSlotDataSingle(
        bytes32 shieldAddress,
        bytes32 tokenBytes32,
        bytes32 l2TokenContractId,
        uint256 amount,
        uint32 chainIndex,
        bytes32 noteCommitment
    ) internal pure returns (uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData) {
        uint256[] memory shieldWords = _bytes32ToWords(shieldAddress);
        uint256[] memory tokenWords = _bytes32ToWords(tokenBytes32);
        uint256[] memory l2TokenWords = _bytes32ToWords(l2TokenContractId);
        uint256[] memory amountWords = _uint256ToWords(amount);
        for (uint256 i = 0; i < 8; ++i) {
            slotData[i] = shieldWords[i];
            slotData[8 + i] = tokenWords[i];
            slotData[16 + i] = l2TokenWords[i];
            slotData[24 + i] = amountWords[i];
            slotData[33 + i] = _bytes32ToWords(noteCommitment)[i];
        }
        slotData[32] = chainIndex;
    }

    function _buildRecordedDepositSlotDataSingle()
        internal
        pure
        returns (uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData)
    {
        return _buildDepositBatchSlotDataSingle(
            bytes32(uint256(2)),
            bytes32(uint256(uint160(address(0x1234)))),
            bytes32(uint256(1)),
            1,
            0,
            bytes32(uint256(3))
        );
    }

    function testClaimWithdrawalWithProof() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(verifier), address(verifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));

        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(77));
        token.mint(address(bridge), amount);

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0x1234)), 0);

        vm.prank(owner);
        sm.finalize(_dummyGnarkProof(), depositRoot, _roots(bytes32(uint256(1)), bytes32(uint256(2))), withdrawalRoot, 0, 1, depositProof, withdrawalProof);

        uint256[8] memory proof;
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), amount, nonce, 0, 0);
        WithdrawalBatchHashVerifier verifierBatch =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifierBatch));

        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(token.balanceOf(user), 0);
        vm.prank(user);
        bridge.claimPendingWithdrawal(nonce);
        assertEq(token.balanceOf(user), amount);
    }

    function testBatchClaimWithdrawalSkipsHighBitAddressSlotsAndSettlesValidSlot() public {
        (Bridge bridge, StateManager sm, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 badRecipientNonce = bytes32(uint256(0x71));
        bytes32 badTokenNonce = bytes32(uint256(0x72));
        bytes32 goodNonce = bytes32(uint256(0x73));
        token.mint(address(bridge), amount);

        BatchClaimItem[] memory items = new BatchClaimItem[](3);
        items[0] = BatchClaimItem(0, user, address(token), amount, badRecipientNonce, 0);
        items[1] = BatchClaimItem(0, user, address(token), amount, badTokenNonce, 0);
        items[2] = BatchClaimItem(0, user, address(token), amount, goodNonce, 0);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        // High bits on recipient (slot 0) and token (slot 1) must be smuggled in via raw words.
        slotData[1] = 1;
        slotData[WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS + 9] = 1;
        _patchBatchCommit(publicInputs, slotData);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256 totalBefore = bridge.totalWithdrawalAmount(address(token));
        uint256[8] memory proof;
        vm.recordLogs();
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 2);
        assertEq(failedSlots[0], 0);
        assertEq(failedSlots[1], 1);
        assertEq(reasons.length, 2);
        assertEq(reasons[0], bridge.CLAIM_REASON_ADDRESS_HIGH_BITS());
        assertEq(reasons[1], bridge.CLAIM_REASON_ADDRESS_HIGH_BITS());
        assertFalse(bridge.claimedNullifiers(badRecipientNonce));
        assertFalse(bridge.claimedNullifiers(badTokenNonce));
        assertTrue(bridge.claimedNullifiers(goodNonce));
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(goodNonce);
        assertEq(pendingAmount, amount);
        assertEq(bridge.totalWithdrawalAmount(address(token)), totalBefore + amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "two ItemFailed, one PendingCreated, one BatchResult");
        assertEq(logs[0].emitter, address(bridge));
        assertEq(logs[0].topics[0], Bridge.WithdrawalClaimItemFailed.selector);
        assertEq(logs[0].topics[1], badRecipientNonce);
        assertEq(uint256(logs[0].topics[2]), 0);
        assertEq(uint256(abi.decode(logs[0].data, (bytes32))), bridge.CLAIM_REASON_ADDRESS_HIGH_BITS(), "reason is non-indexed data");
        assertEq(logs[1].topics[0], Bridge.WithdrawalClaimItemFailed.selector);
        assertEq(logs[1].topics[1], badTokenNonce);
        assertEq(uint256(logs[1].topics[2]), 1);
        assertEq(logs[2].topics[0], Bridge.WithdrawalPendingCreated.selector);
        assertEq(logs[2].topics[1], goodNonce);
        assertEq(logs[3].topics[0], Bridge.WithdrawalClaimBatchResult.selector);
        assertEq(logs[3].topics[1], _batchCommitBytes32(publicInputs));
        (uint8 realCount, uint8 succeeded, uint8 failed) = abi.decode(logs[3].data, (uint8, uint8, uint8));
        assertEq(realCount, 3);
        assertEq(succeeded, 1);
        assertEq(failed, 2);
        assertEq(uint256(sm.l1ChainIndex()), 0, "l1ChainIndex must be the single-chain default");
    }

    function testClaimWithdrawalAcceptsPreviouslyFinalizedSubtreeRoot() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(verifier), address(verifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(77));
        token.mint(address(bridge), amount);

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProofA, bytes32 depositRootA) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProofA, bytes32 withdrawalRootA) = _mkTopProof(bytes32(uint256(0x1234)), 0);

        vm.prank(owner);
        sm.finalize(_dummyGnarkProof(), depositRootA, _roots(bytes32(uint256(1)), bytes32(uint256(2))), withdrawalRootA, 0, 1, depositProofA, withdrawalProofA);

        bytes32 depositLeafB = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProofB, bytes32 depositRootB) = _mkTopProof(depositLeafB, 0);
        (bytes32[9] memory withdrawalProofB, bytes32 withdrawalRootB) = _mkTopProof(bytes32(uint256(0x5678)), 0);

        vm.prank(owner);
        sm.finalize(_dummyGnarkProof(), depositRootB, _roots(bytes32(uint256(2)), bytes32(uint256(3))), withdrawalRootB, 0, 2, depositProofB, withdrawalProofB);

        uint256[8] memory proof;
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProofA[0], 0, user, address(token), amount, nonce, 0, 0);
        WithdrawalBatchHashVerifier verifierBatch =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifierBatch));

        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(token.balanceOf(user), 0);
        vm.prank(user);
        bridge.claimPendingWithdrawal(nonce);
        assertEq(token.balanceOf(user), amount);
    }

    function testBatchClaimWithdrawalSnapshotsDelayAndSettlesFullAmountOnce() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 100;
        config.mediumWithdrawalMax = 200;
        config.totalWithdrawalCap = 200;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, address(token), config);
        config.mediumWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, address(token), config);
        uint256 amount = 150;
        bytes32 nonce = bytes32(uint256(88));
        token.mint(address(bridge), amount);

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0x1234)), 0);

        vm.prank(owner);
        sm.finalize(_dummyGnarkProof(), depositRoot, _roots(bytes32(uint256(1)), bytes32(uint256(2))), withdrawalRoot, 0, 1, depositProof, withdrawalProof);

        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), amount, nonce, 0, 0);
        WithdrawalBatchHashVerifier verifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifier));

        uint256[8] memory proof;
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        (,, uint256 pendingAmount, uint64 claimableAt) = bridge.pendingWithdrawals(nonce);
        assertEq(token.balanceOf(user), 0);
        assertEq(pendingAmount, amount);
        assertEq(claimableAt, block.timestamp + 3_600);
        assertTrue(bridge.claimedNullifiers(nonce));

        config.largeWithdrawalDelay = 7_200;
        _setFlowConfig(bridge, address(token), config);
        (,,, uint64 snapshottedClaimableAt) = bridge.pendingWithdrawals(nonce);
        assertEq(snapshottedClaimableAt, claimableAt, "config update must not change an existing ETA");

        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotClaimable.selector, nonce, claimableAt));
        bridge.claimPendingWithdrawal(nonce);

        address keeper = address(0xCAFE);
        vm.warp(claimableAt);
        vm.prank(owner);
        bridge.setTokenPauseFlags(address(token), 4);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingClaimsPaused.selector, address(token)));
        bridge.claimPendingWithdrawal(nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(address(token), 0);
        vm.prank(keeper);
        bridge.claimPendingWithdrawal(nonce);
        assertEq(token.balanceOf(user), amount);
        (,, pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, 0);
        assertEq(token.balanceOf(address(bridge)), 0);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, nonce));
        bridge.claimPendingWithdrawal(nonce);
    }

    function testBatchClaimWithdrawalRejectsZeroRealCount() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        uint256[18] memory publicInputs;
        uint256[1088] memory slotData;
        for (uint256 i = 0; i < 8; ++i) {
            publicInputs[i] = _bytes32ToWords(bytes32(uint256(1)))[i];
        }
        publicInputs[8] = 0;
        publicInputs[9] = 524288;

        WithdrawalBatchHashVerifier verifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifier));

        uint256[8] memory proof;
        vm.prank(user);
        vm.expectRevert(Bridge.InvalidRealCount.selector);
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);
    }

    function testBatchClaimWithdrawalHonorsRegistrationPauseWithoutConsumingNullifier() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(99));

        BatchClaimItem[] memory items = _singleItem(BatchClaimItem(0, user, address(token), amount, nonce, 0));
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);
        vm.prank(owner);
        bridge.setTokenPauseFlags(address(token), 2);

        uint256[8] memory proof;
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 0);
        assertEq(reasons[0], bridge.CLAIM_REASON_REGISTRATION_PAUSED());
        assertFalse(bridge.claimedNullifiers(nonce));
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, 0);
        assertEq(bridge.totalWithdrawalAmount(address(token)), 0);
    }

    function testBatchClaimWithdrawalPriorClaimedNonceSkipsAndContinues() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 claimedNonce = bytes32(uint256(0x81));
        bytes32 freshNonce = bytes32(uint256(0x82));

        BatchClaimItem[] memory first =
            _singleItem(BatchClaimItem(0, user, address(token), amount, claimedNonce, 0));
        (uint256[18] memory firstInputs, uint256[1088] memory firstSlotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, first);
        _setBatchClaimVerifier(bridge, firstInputs);
        uint256[8] memory proof;
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, firstInputs, firstSlotData);
        assertTrue(bridge.claimedNullifiers(claimedNonce));
        (,, uint256 claimedAmount, uint64 claimedClaimableAt) = bridge.pendingWithdrawals(claimedNonce);

        BatchClaimItem[] memory second = new BatchClaimItem[](2);
        second[0] = BatchClaimItem(0, user, address(token), amount, claimedNonce, 0);
        second[1] = BatchClaimItem(0, user, address(token), amount, freshNonce, 0);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, second);
        _setBatchClaimVerifier(bridge, publicInputs);

        vm.recordLogs();
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 0);
        assertEq(reasons[0], bridge.CLAIM_REASON_NULLIFIER_ALREADY_CLAIMED());
        assertTrue(bridge.claimedNullifiers(claimedNonce));
        assertTrue(bridge.claimedNullifiers(freshNonce));
        (,, uint256 pendingAfter, uint64 claimableAfter) = bridge.pendingWithdrawals(claimedNonce);
        assertEq(pendingAfter, claimedAmount);
        assertEq(claimableAfter, claimedClaimableAt, "prior pending entry must not be re-registered");
        (,, uint256 freshAmount,) = bridge.pendingWithdrawals(freshNonce);
        assertEq(freshAmount, amount);
        assertEq(bridge.totalWithdrawalAmount(address(token)), claimedAmount + amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3, "ItemFailed, PendingCreated, BatchResult");
        assertEq(logs[0].topics[0], Bridge.WithdrawalClaimItemFailed.selector);
        assertEq(logs[0].topics[1], claimedNonce);
        assertEq(uint256(logs[0].topics[2]), 0);
        assertEq(logs[1].topics[0], Bridge.WithdrawalPendingCreated.selector);
        assertEq(logs[1].topics[1], freshNonce);
        assertEq(logs[2].topics[0], Bridge.WithdrawalClaimBatchResult.selector);
    }

    function testBatchClaimWithdrawalDuplicateNonceInBatchRegistersOnce() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(0x83));
        bytes32 otherNonce = bytes32(uint256(0x84));

        BatchClaimItem[] memory items = new BatchClaimItem[](3);
        items[0] = BatchClaimItem(0, user, address(token), amount, nonce, 0);
        items[1] = BatchClaimItem(0, user, address(token), amount, nonce, 0);
        items[2] = BatchClaimItem(0, user, address(token), amount, otherNonce, 0);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256[8] memory proof;
        vm.recordLogs();
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 1);
        assertEq(reasons[0], bridge.CLAIM_REASON_NULLIFIER_ALREADY_CLAIMED());
        assertTrue(bridge.claimedNullifiers(nonce));
        assertTrue(bridge.claimedNullifiers(otherNonce));
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, amount);
        assertEq(bridge.totalWithdrawalAmount(address(token)), 2 * amount);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "PendingCreated, ItemFailed, PendingCreated, BatchResult");
        assertEq(logs[0].topics[0], Bridge.WithdrawalPendingCreated.selector);
        assertEq(logs[0].topics[1], nonce);
        assertEq(logs[1].topics[0], Bridge.WithdrawalClaimItemFailed.selector);
        assertEq(logs[1].topics[1], nonce, "same nonce may appear in both event kinds");
        assertEq(uint256(logs[1].topics[2]), 1, "failed slot index, not nonce, disambiguates");
        assertEq(uint256(abi.decode(logs[1].data, (bytes32))), bridge.CLAIM_REASON_NULLIFIER_ALREADY_CLAIMED(), "reason is non-indexed data");
        assertEq(logs[2].topics[0], Bridge.WithdrawalPendingCreated.selector);
        assertEq(logs[2].topics[1], otherNonce);
        assertEq(logs[3].topics[0], Bridge.WithdrawalClaimBatchResult.selector);
    }

    function testBatchClaimWithdrawalAllSlotsFailSucceedsWithoutStateChange() public {
        (Bridge bridge, StateManager sm, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        MockERC20 unconfigured = new MockERC20("Unconfigured", "UNCF");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        uint8 chainIndex = sm.l1ChainIndex();

        BatchClaimItem[] memory items = new BatchClaimItem[](5);
        items[0] = BatchClaimItem(0, address(0), address(token), amount, bytes32(uint256(0x91)), 0);
        items[1] = BatchClaimItem(0, user, address(token), 0, bytes32(uint256(0x92)), 0);
        items[2] = BatchClaimItem(0, user, address(token), amount, bytes32(uint256(0x93)), chainIndex + 1);
        items[3] = BatchClaimItem(0, user, address(unconfigured), amount, bytes32(uint256(0x94)), 0);
        items[4] = BatchClaimItem(0, user, address(token), amount, bytes32(uint256(0x95)), 0);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        slotData[4 * WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS + 1] = 1;
        _patchBatchCommit(publicInputs, slotData);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256[8] memory proof;
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 5);
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(failedSlots[i], i);
        }
        assertEq(reasons[0], bridge.CLAIM_REASON_ZERO_ADDRESS());
        assertEq(reasons[1], bridge.CLAIM_REASON_ZERO_AMOUNT());
        assertEq(reasons[2], bridge.CLAIM_REASON_WRONG_DESTINATION_CHAIN());
        assertEq(reasons[3], bridge.CLAIM_REASON_TOKEN_NOT_CONFIGURED());
        assertEq(reasons[4], bridge.CLAIM_REASON_ADDRESS_HIGH_BITS());
        for (uint256 i = 0; i < 5; ++i) {
            assertFalse(bridge.claimedNullifiers(bytes32(uint256(0x91 + i))));
        }
        assertEq(bridge.totalWithdrawalAmount(address(token)), 0);
        assertEq(bridge.totalWithdrawalAmount(address(unconfigured)), 0);
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(bytes32(uint256(0x91)));
        assertEq(pendingAmount, 0);
    }

    function testBatchClaimWithdrawalCommitMismatchRevertsWithZeroEffects() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(0x96));

        BatchClaimItem[] memory items = _singleItem(BatchClaimItem(0, user, address(token), amount, nonce, 0));
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);
        // Corrupt the committed slot set after the verifier was pinned to the honest hash.
        slotData[0] = 1;

        uint256[8] memory proof;
        vm.recordLogs();
        vm.prank(user);
        vm.expectRevert(Bridge.InvalidWithdrawalProof.selector);
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);
        assertEq(vm.getRecordedLogs().length, 0, "no events may survive a whole-proof revert");
        assertFalse(bridge.claimedNullifiers(nonce));
        assertEq(bridge.totalWithdrawalAmount(address(token)), 0);
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, 0);
    }

    function testBatchClaimWithdrawalAmountOutOfRangeBoundary() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 maxValidAmount = GOLDILOCKS_PRIME - 1;
        bytes32 okNonce = bytes32(uint256(0x97));
        bytes32 badNonce = bytes32(uint256(0x98));

        BatchClaimItem[] memory items = new BatchClaimItem[](2);
        items[0] = BatchClaimItem(0, user, address(token), maxValidAmount, okNonce, 0);
        items[1] = BatchClaimItem(0, user, address(token), GOLDILOCKS_PRIME, badNonce, 0);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256[8] memory proof;
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 1);
        assertEq(reasons[0], bridge.CLAIM_REASON_AMOUNT_OUT_OF_RANGE());
        assertTrue(bridge.claimedNullifiers(okNonce));
        assertFalse(bridge.claimedNullifiers(badNonce));
        assertEq(bridge.totalWithdrawalAmount(address(token)), maxValidAmount);
    }

    function testBatchClaimWithdrawalTotalOverflowBoundary() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 10;
        bytes32 okNonce = bytes32(uint256(0xA1));
        bytes32 badNonce = bytes32(uint256(0xA2));

        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = address(token);
        uint256[] memory historicalTotals = new uint256[](1);
        historicalTotals[0] = type(uint256).max - amount;
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(
            configuredTokens, _flowConfigs(1), historicalTotals, _tokenSetHash(configuredTokens), address(this)
        );

        BatchClaimItem[] memory items = new BatchClaimItem[](2);
        items[0] = BatchClaimItem(0, user, address(token), amount, okNonce, 0);
        items[1] = BatchClaimItem(0, user, address(token), amount, badNonce, 0);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256[8] memory proof;
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 1);
        assertEq(reasons[0], bridge.CLAIM_REASON_TOTAL_AMOUNT_OVERFLOW());
        assertTrue(bridge.claimedNullifiers(okNonce));
        assertFalse(bridge.claimedNullifiers(badNonce));
        assertEq(bridge.totalWithdrawalAmount(address(token)), type(uint256).max);
    }

    function testBatchClaimWithdrawalClaimableAtOverflowBoundary() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 100;
        config.mediumWithdrawalMax = 200;
        config.totalWithdrawalCap = 200;
        config.largeWithdrawalDelay = 1_000;
        _setFlowConfig(bridge, address(token), config);

        uint256 amount = 250;
        bytes32 boundaryNonce = bytes32(uint256(0xB1));
        bytes32 overflowNonce = bytes32(uint256(0xB2));

        BatchClaimItem[] memory boundaryItems =
            _singleItem(BatchClaimItem(0, user, address(token), amount, boundaryNonce, 0));
        (uint256[18] memory boundaryInputs, uint256[1088] memory boundarySlotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, boundaryItems);
        _setBatchClaimVerifier(bridge, boundaryInputs);
        uint256[8] memory proof;
        vm.warp(type(uint64).max - config.largeWithdrawalDelay);
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, boundaryInputs, boundarySlotData);
        (,,, uint64 claimableAt) = bridge.pendingWithdrawals(boundaryNonce);
        assertEq(uint256(claimableAt), uint256(type(uint64).max), "claim time exactly at uint64 max must be accepted");

        BatchClaimItem[] memory overflowItems =
            _singleItem(BatchClaimItem(0, user, address(token), amount, overflowNonce, 0));
        (uint256[18] memory overflowInputs, uint256[1088] memory overflowSlotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, overflowItems);
        _setBatchClaimVerifier(bridge, overflowInputs);
        vm.warp(type(uint64).max - config.largeWithdrawalDelay + 1);
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) =
            bridge.batchClaimWithdrawal(proof, overflowInputs, overflowSlotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 0);
        assertEq(reasons[0], bridge.CLAIM_REASON_CLAIMABLE_AT_OVERFLOW());
        assertFalse(bridge.claimedNullifiers(overflowNonce));
    }

    function testBatchClaimWithdrawalFailedArraysAndLogsMapToInputPositions() public {
        (Bridge bridge, StateManager sm, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        uint8 chainIndex = sm.l1ChainIndex();
        bytes32 nonceA = bytes32(uint256(0xC1));
        bytes32 zeroAmountNonce = bytes32(uint256(0xC2));
        bytes32 nonceB = bytes32(uint256(0xC3));
        bytes32 wrongChainNonce = bytes32(uint256(0xC4));

        BatchClaimItem[] memory items = new BatchClaimItem[](4);
        items[0] = BatchClaimItem(0, user, address(token), amount, nonceA, 0);
        items[1] = BatchClaimItem(0, user, address(token), 0, zeroAmountNonce, 0);
        items[2] = BatchClaimItem(0, user, address(token), amount, nonceB, 0);
        items[3] = BatchClaimItem(0, user, address(token), amount, wrongChainNonce, chainIndex + 1);
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256[8] memory proof;
        vm.recordLogs();
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 2);
        assertEq(failedSlots[0], 1);
        assertEq(failedSlots[1], 3);
        assertEq(reasons[0], bridge.CLAIM_REASON_ZERO_AMOUNT());
        assertEq(reasons[1], bridge.CLAIM_REASON_WRONG_DESTINATION_CHAIN());
        assertTrue(bridge.claimedNullifiers(nonceA));
        assertTrue(bridge.claimedNullifiers(nonceB));
        assertFalse(bridge.claimedNullifiers(zeroAmountNonce));
        assertFalse(bridge.claimedNullifiers(wrongChainNonce));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 5, "per-slot events in input order, summary last");
        assertEq(logs[0].topics[0], Bridge.WithdrawalPendingCreated.selector);
        assertEq(logs[0].topics[1], nonceA);
        assertEq(logs[1].topics[0], Bridge.WithdrawalClaimItemFailed.selector);
        assertEq(logs[1].topics[1], zeroAmountNonce);
        assertEq(uint256(logs[1].topics[2]), 1);
        assertEq(uint256(abi.decode(logs[1].data, (bytes32))), bridge.CLAIM_REASON_ZERO_AMOUNT(), "reason is non-indexed data");
        assertEq(logs[2].topics[0], Bridge.WithdrawalPendingCreated.selector);
        assertEq(logs[2].topics[1], nonceB);
        assertEq(logs[3].topics[0], Bridge.WithdrawalClaimItemFailed.selector);
        assertEq(logs[3].topics[1], wrongChainNonce);
        assertEq(uint256(logs[3].topics[2]), 3);
        assertEq(uint256(abi.decode(logs[3].data, (bytes32))), bridge.CLAIM_REASON_WRONG_DESTINATION_CHAIN(), "reason is non-indexed data");
        assertEq(logs[4].topics[0], Bridge.WithdrawalClaimBatchResult.selector);
        (uint8 realCount, uint8 succeeded, uint8 failed) = abi.decode(logs[4].data, (uint8, uint8, uint8));
        assertEq(realCount, 4);
        assertEq(succeeded, 2);
        assertEq(failed, 2);
    }

    function testPerTokenDepositLimitsIsolationAndDynamicConfigUpdate() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address tokenA = address(0x1234);
        address tokenB = address(0x5678);
        MockERC20 mockToken = new MockERC20("Mock B", "MOCKB");
        vm.etch(tokenB, address(mockToken).code);

        vm.etch(tokenA, address(mockToken).code);
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.minDepositAmount = 100;
        config.depositCap = 500;
        _setFlowConfig(bridge, tokenA, config);
        _setFlowConfig(bridge, tokenB, config);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositBelowMinimum.selector, tokenA, 99, 100));
        bridge.recordDepositFromGateway(tokenA, bytes32(uint256(1)), 99, bytes32(uint256(2)), bytes32(uint256(3)));

        MockERC20(tokenA).mint(address(bridge), 501);
        vm.prank(owner);
        bridge.recordDepositFromGateway(tokenA, bytes32(uint256(1)), 100, bytes32(uint256(4)), bytes32(uint256(5)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositCapExceeded.selector, tokenA, 501, 500));
        bridge.recordDepositFromGateway(tokenA, bytes32(uint256(1)), 501, bytes32(uint256(8)), bytes32(uint256(9)));

        vm.prank(owner);
        bridge.recordDepositFromGateway(tokenB, bytes32(uint256(1)), 400, bytes32(uint256(6)), bytes32(uint256(7)));

        bytes32 oldHash = bridge.getTokenFlowConfigHash(tokenA);
        config.depositCap = 1_000;
        _setFlowConfig(bridge, tokenA, config);
        assertEq(bridge.getTokenFlowConfig(tokenA).depositCap, 1_000);

        bytes32 currentHash = bridge.getTokenFlowConfigHash(tokenA);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.StaleConfigHash.selector, oldHash, currentHash));
        bridge.setTokenFlowConfig(tokenA, config, oldHash);
    }


    function testDepositExactBoundariesAndDepositCap() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.minDepositAmount = 100;
        config.depositCap = 1_000;
        _setFlowConfig(bridge, token, config);

        vm.startPrank(owner);
        bridge.recordDepositFromGateway(token, bytes32(uint256(1)), 100, bytes32(uint256(2)), bytes32(uint256(3)));
        bridge.recordDepositFromGateway(token, bytes32(uint256(1)), 900, bytes32(uint256(4)), bytes32(uint256(5)));
        vm.stopPrank();

        MockERC20(token).mint(address(bridge), 1_001);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositCapExceeded.selector, token, 1_001, 1_000));
        bridge.recordDepositFromGateway(token, bytes32(uint256(1)), 1_001, bytes32(uint256(10)), bytes32(uint256(11)));
    }

    function testInitializeWithdrawalTotalsValidatesInputsAndStoresAnyUint256Baseline() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        address otherToken = address(0x5678);
        _configureFlowToken(bridge, otherToken);

        address[] memory tokens = new address[](2);
        tokens[0] = token;
        tokens[1] = otherToken;
        uint256[] memory totals = new uint256[](2);
        totals[0] = type(uint256).max;
        totals[1] = 42;
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, _tokenSetHash(tokens), address(this));
        assertEq(bridge.totalWithdrawalAmount(token), type(uint256).max);
        assertEq(bridge.totalWithdrawalAmount(otherToken), 42);
    }

    function testInitializeWithdrawalTotalsRejectsDuplicatesAndUnconfiguredTokens() public {
        (Bridge duplicateBridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        address[] memory duplicateTokens = new address[](2);
        duplicateTokens[0] = token;
        duplicateTokens[1] = token;
        uint256[] memory duplicateTotals = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DuplicateToken.selector, token));
        duplicateBridge.initializeWithdrawalTotals(duplicateTokens, _flowConfigs(duplicateTokens.length), duplicateTotals, _tokenSetHash(duplicateTokens), address(this));

        (Bridge unconfiguredBridge,) = _setupBridgeSystem();
        address unconfigured = address(0x9876);
        address[] memory tokens = new address[](1);
        tokens[0] = unconfigured;
        uint256[] memory totals = new uint256[](1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.TokenNotConfigured.selector, unconfigured));
        unconfiguredBridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, _tokenSetHash(tokens), address(this));
    }

    function testInitializeWithdrawalTotalsRejectsInvalidExecutorAndTokenSetHashAtomically() public {
        (Bridge zeroExecutorBridge,) = _setupBridgeSystem();
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x1234);
        uint256[] memory totals = new uint256[](1);
        totals[0] = 77;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Bridge.InvalidWithdrawalForceClaimExecutor.selector, address(0))
        );
        zeroExecutorBridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, _tokenSetHash(tokens), address(0));
        assertEq(zeroExecutorBridge.totalWithdrawalAmount(tokens[0]), 0);

        (Bridge eoaExecutorBridge,) = _setupBridgeSystem();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.InvalidWithdrawalForceClaimExecutor.selector, user));
        eoaExecutorBridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, _tokenSetHash(tokens), user);
        assertEq(eoaExecutorBridge.totalWithdrawalAmount(tokens[0]), 0);

        (Bridge badHashBridge,) = _setupBridgeSystem();
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Bridge.WithdrawalTotalsTokenSetHashMismatch.selector,
                bytes32(uint256(1)),
                _tokenSetHash(tokens)
            )
        );
        badHashBridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, bytes32(uint256(1)), address(this));
        assertEq(badHashBridge.totalWithdrawalAmount(tokens[0]), 0);
        assertEq(badHashBridge.withdrawalForceClaimExecutor(), address(0));
        assertEq(badHashBridge.withdrawalTotalsTokenSetHash(), bytes32(0));
    }



    function testZeroDelaySmallAndMediumImmediatelyClaimableLargeDelayed() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 100;
        config.mediumWithdrawalMax = 200;
        config.totalWithdrawalCap = 200;
        config.smallWithdrawalDelay = 0;
        config.mediumWithdrawalDelay = 0;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, address(token), config);

        uint256 smallAmount = 50;
        uint256 mediumAmount = 150;
        uint256 largeAmount = 250;
        bytes32 smallNonce = bytes32(uint256(0x11));
        bytes32 mediumNonce = bytes32(uint256(0x22));
        bytes32 largeNonce = bytes32(uint256(0x33));
        token.mint(address(bridge), smallAmount + mediumAmount + largeAmount);

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0x1234)), 0);
        vm.prank(owner);
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

        uint256[8] memory proof;
        (uint256[18] memory smallInputs, uint256[1088] memory smallSlotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), smallAmount, smallNonce, 0, 0);
        WithdrawalBatchHashVerifier smallVerifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(smallInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(smallVerifier));
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, smallInputs, smallSlotData);

        (uint256[18] memory mediumInputs, uint256[1088] memory mediumSlotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), mediumAmount, mediumNonce, 0, 0);
        WithdrawalBatchHashVerifier mediumVerifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(mediumInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(mediumVerifier));
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, mediumInputs, mediumSlotData);

        (uint256[18] memory largeInputs, uint256[1088] memory largeSlotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), largeAmount, largeNonce, 0, 0);
        WithdrawalBatchHashVerifier largeVerifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(largeInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(largeVerifier));
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, largeInputs, largeSlotData);

        (,, uint256 smallPending, uint64 smallClaimableAt) = bridge.pendingWithdrawals(smallNonce);
        (,, uint256 mediumPending, uint64 mediumClaimableAt) = bridge.pendingWithdrawals(mediumNonce);
        (,, uint256 largePending, uint64 largeClaimableAt) = bridge.pendingWithdrawals(largeNonce);
        assertEq(smallPending, 0);
        assertEq(token.balanceOf(user), smallAmount);
        assertEq(mediumPending, mediumAmount);
        assertEq(largePending, largeAmount);
        assertEq(smallClaimableAt, 0, "small tier must not create a pending entry");
        assertEq(mediumClaimableAt, block.timestamp, "zero-delay medium tier must be immediately claimable");
        assertEq(largeClaimableAt, block.timestamp + 3_600, "large tier delay must remain enforced");

        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, smallNonce));
        bridge.claimPendingWithdrawal(smallNonce);
        vm.prank(user);
        bridge.claimPendingWithdrawal(mediumNonce);
        assertEq(token.balanceOf(user), smallAmount + mediumAmount);

        vm.expectRevert(abi.encodeWithSelector(Bridge.WithdrawalGovernanceRequired.selector, largeNonce));
        bridge.claimPendingWithdrawal(largeNonce);

        vm.warp(largeClaimableAt);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Bridge.WithdrawalGovernanceRequired.selector, largeNonce));
        bridge.claimPendingWithdrawal(largeNonce);
        assertEq(token.balanceOf(user), smallAmount + mediumAmount);
    }

    function testForceClaimWithdrawalHonorsDelayIsAdminOnlyPausedSafeAndOneShot() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));
        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();
        MockERC20 token = new MockERC20("Mock", "MOCK");
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 10;
        config.mediumWithdrawalMax = 20;
        config.totalWithdrawalCap = 20;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, address(token), config);
        token.mint(address(bridge), 30);

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0xFA)), 0);
        vm.prank(owner);
        sm.finalize(
            _dummyGnarkProof(), depositRoot, _roots(bytes32(uint256(1)), bytes32(uint256(2))),
            withdrawalRoot, 0, 1, depositProof, withdrawalProof
        );
        bytes32 nonce = bytes32(uint256(0xFB));
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), 30, nonce, 0, 0);
        WithdrawalBatchHashVerifier verifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifier));
        uint256[8] memory proof;
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);
        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = address(token);
        uint256[] memory historicalTotals = new uint256[](1);
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(
            configuredTokens, _flowConfigs(configuredTokens.length), historicalTotals, _tokenSetHash(configuredTokens), address(this)
        );

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Bridge.UnauthorizedWithdrawalForceClaimExecutor.selector, user));
        bridge.forceClaimWithdrawal(nonce);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.UnauthorizedWithdrawalForceClaimExecutor.selector, owner));
        bridge.forceClaimWithdrawal(nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(address(token), 4);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingClaimsPaused.selector, address(token)));
        bridge.forceClaimWithdrawal(nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(address(token), 0);
        (,,, uint64 claimableAt) = bridge.pendingWithdrawals(nonce);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotClaimable.selector, nonce, claimableAt));
        bridge.forceClaimWithdrawal(nonce);
        vm.warp(claimableAt);
        bridge.forceClaimWithdrawal(nonce);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, nonce));
        bridge.forceClaimWithdrawal(nonce);
        assertEq(token.balanceOf(user), 30);
    }


    function testZeroSmallMediumDelayConfigAcceptedWithLargeDelay() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalDelay = 0;
        config.mediumWithdrawalDelay = 0;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, token, config);

        assertEq(
            bridge.getTokenFlowConfigHash(token),
            keccak256(abi.encode(token, config)),
            "zero small/medium delay with nonzero large delay must be a valid config"
        );
    }

    function testInvalidFlowConfigMatrixAndPauseFlagValidation() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        Bridge.TokenFlowConfig memory config;

        config = _defaultFlowConfig();
        config.configured = false;
        _expectInvalidFlowConfig(bridge, token, config);
        config = _defaultFlowConfig();
        config.minDepositAmount = 0;
        _expectInvalidFlowConfig(bridge, token, config);
        config = _defaultFlowConfig();
        config.depositCap = config.minDepositAmount - 1;
        _expectInvalidFlowConfig(bridge, token, config);
        config = _defaultFlowConfig();
        config.smallWithdrawalMax = config.mediumWithdrawalMax + 1;
        _expectInvalidFlowConfig(bridge, token, config);
        config = _defaultFlowConfig();
        config.smallWithdrawalDelay = config.mediumWithdrawalDelay + 1;
        _expectInvalidFlowConfig(bridge, token, config);
        config = _defaultFlowConfig();
        config.mediumWithdrawalDelay = config.largeWithdrawalDelay + 1;
        _expectInvalidFlowConfig(bridge, token, config);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.InvalidPauseFlags.selector, uint8(8)));
        bridge.setGlobalPauseFlags(8);
    }

    function _expectInvalidFlowConfig(Bridge bridge, address token, Bridge.TokenFlowConfig memory config) internal {
        bytes32 expectedHash = bridge.getTokenFlowConfigHash(token);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.InvalidFlowConfig.selector, token));
        bridge.setTokenFlowConfig(token, config, expectedHash);
    }

    function testGuardianCanOnlyAddPauseFlagsAndAdminCanClearThem() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        PsyAddressesProvider provider = PsyAddressesProvider(bridge.addressesProvider());
        PsyACLManager acl = PsyACLManager(provider.getAddress(provider.ACL_MANAGER_ID()));

        bytes32 guardianRole = acl.GUARDIAN_ROLE();
        vm.prank(owner);
        acl.grantRole(guardianRole, user);

        bytes32 configHash = bridge.getTokenFlowConfigHash(token);
        vm.prank(user);
        bridge.guardianPauseToken(token, 1);
        assertEq(bridge.getTokenFlowConfigHash(token), configHash, "pause state must not change config hash");
        (,, uint8 effectiveFlags) = bridge.getPauseFlags(token);
        assertEq(effectiveFlags, 1);

        vm.prank(user);
        bridge.guardianPauseToken(token, 0);
        (,, effectiveFlags) = bridge.getPauseFlags(token);
        assertEq(effectiveFlags, 1, "guardian cannot clear pause flags");

        vm.prank(user);
        vm.expectRevert(Bridge.UnauthorizedBridgeAdmin.selector);
        bridge.setTokenPauseFlags(token, 0);

        vm.prank(owner);
        bridge.setTokenPauseFlags(token, 0);
        (,, effectiveFlags) = bridge.getPauseFlags(token);
        assertEq(effectiveFlags, 0);
    }

    function testRescueRequiresBridgeAdminAndFullyPausedBridge() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        MockERC20(token).mint(address(bridge), 100);

        vm.prank(user);
        vm.expectRevert(Bridge.UnauthorizedBridgeAdmin.selector);
        bridge.rescueERC20(token, user, 100);

        vm.prank(owner);
        vm.expectRevert(Bridge.BridgeNotFullyPaused.selector);
        bridge.rescueERC20(token, user, 100);

        vm.startPrank(owner);
        bridge.setGlobalPauseFlags(7);
        bridge.rescueERC20(token, user, 100);
        vm.stopPrank();
        assertEq(MockERC20(token).balanceOf(user), 100);
    }

    function testBatchAppendRejectsDepositRootMismatch() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));

        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(bytes32(uint256(123)), bytes32(uint256(456)), 0, 1, bytes32(0));
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData;
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.DepositRootMismatch.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendRejectsFrontierMismatch() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));

        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildRecordedDepositSlotDataSingle();
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slotData));
        _setWord(publicInputs, 18 + 32 * 8, 1);
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.DepositFrontierMismatch.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendRejectsInvalidBatchRange() public {
        (Bridge bridge,) = _setupBridgeSystem();

        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 1, 0, bytes32(0));
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData;
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidBatchRange.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendRejectsInvalidPublicInputsPacking() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));

        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildRecordedDepositSlotDataSingle();
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slotData));
        assembly ("memory-safe") {
            mstore(publicInputs, sub(mload(publicInputs), 0x20))
        }
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidPublicInputs.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendRejectsInvalidDepositBatchProof() public {
        (Bridge bridge, MockGnarkVerifier verifier) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));

        verifier.setShouldVerify(false);
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildRecordedDepositSlotDataSingle();
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slotData));
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidDepositBatchProof.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendRejectsDepositAntiForgeryMismatch() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));

        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, bytes32(uint256(999)));
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildRecordedDepositSlotDataSingle();
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.DepositBatchCommitMismatch.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendRejectsAmountMutation() public {
        _assertSingleDepositFieldMutationReverts(
            bytes32(uint256(2)),
            address(0x1234),
            bytes32(uint256(1)),
            2,
            1,
            bytes32(uint256(3))
        );
    }

    function testBatchAppendRejectsShieldAddressMutation() public {
        _assertSingleDepositFieldMutationReverts(
            bytes32(uint256(999)),
            address(0x1234),
            bytes32(uint256(1)),
            1,
            1,
            bytes32(uint256(3))
        );
    }

    function testBatchAppendRejectsTokenMutation() public {
        _assertSingleDepositFieldMutationReverts(
            bytes32(uint256(2)),
            address(0x9999),
            bytes32(uint256(1)),
            1,
            1,
            bytes32(uint256(3))
        );
    }

    function testBatchAppendRejectsL2TokenContractIdMutation() public {
        _assertSingleDepositFieldMutationReverts(
            bytes32(uint256(2)),
            address(0x1234),
            bytes32(uint256(999)),
            1,
            1,
            bytes32(uint256(3))
        );
    }

    function testBatchAppendRejectsSourceChainIndexMutation() public {
        _assertSingleDepositFieldMutationReverts(
            bytes32(uint256(2)),
            address(0x1234),
            bytes32(uint256(1)),
            1,
            9,
            bytes32(uint256(3))
        );
    }

    function testBatchAppendRejectsNoteCommitmentMutation() public {
        _assertSingleDepositFieldMutationReverts(
            bytes32(uint256(2)),
            address(0x1234),
            bytes32(uint256(1)),
            1,
            1,
            bytes32(uint256(999))
        );
    }

    function testBatchAppendRejectsForgedRealCount() public {
        (Bridge bridge,) = _setupBridgeSystem();

        for (uint256 i = 0; i < 10; ++i) {
            vm.prank(owner);
            bridge.recordDepositFromGateway(
                address(0x1234),
                bytes32(uint256(i + 1)),
                i + 1,
                bytes32(uint256(0x200 + i)),
                bytes32(uint256(0x300 + i))
            );
        }

        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData;
        for (uint256 i = 0; i < 5; ++i) {
            uint256 base = i * DEPOSIT_BATCH_APPEND_SLOT_WORDS;
            uint256[] memory shieldWords = _bytes32ToWords(bytes32(uint256(0x200 + i)));
            uint256[] memory tokenWords = _bytes32ToWords(bytes32(uint256(uint160(address(0x1234)))));
            uint256[] memory l2TokenWords = _bytes32ToWords(bytes32(uint256(i + 1)));
            uint256[] memory amountWords = _uint256ToWords(i + 1);
            uint256[] memory noteWords = _bytes32ToWords(bytes32(uint256(0x300 + i)));
            for (uint256 j = 0; j < 8; ++j) {
                slotData[base + j] = shieldWords[j];
                slotData[base + 8 + j] = tokenWords[j];
                slotData[base + 16 + j] = l2TokenWords[j];
                slotData[base + 24 + j] = amountWords[j];
                slotData[base + 33 + j] = noteWords[j];
            }
            slotData[base + 32] = 0;
        }
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 10, _computeDepositBatchSlotDataCommit(slotData));
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.DepositBatchCommitMismatch.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function _assertSingleDepositFieldMutationReverts(
        bytes32 mutatedShieldAddress,
        address mutatedToken,
        bytes32 mutatedL2TokenContractId,
        uint256 mutatedAmount,
        uint32 mutatedChainIndex,
        bytes32 mutatedNoteCommitment
    ) internal {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));

        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildDepositBatchSlotDataSingle(
            mutatedShieldAddress,
            bytes32(uint256(uint160(mutatedToken))),
            mutatedL2TokenContractId,
            mutatedAmount,
            mutatedChainIndex,
            mutatedNoteCommitment
        );
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slotData));
        uint256[8] memory proof;

        vm.prank(owner);
        vm.expectRevert(Bridge.DepositBatchCommitMismatch.selector);
        bridge.batchAppend(proof, publicInputs, slotData);
    }

    function testBatchAppendUsesSingleKeccakPublicInputsHash() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));
        uint256[8] memory proof;

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        provider.setAddress(provider.ERC20_GATEWAY_ID(), owner);
        vm.stopPrank();

        MockERC20 mockToken = new MockERC20("Mock", "MOCK");
        vm.etch(address(0x1234), address(mockToken).code);
        _configureFlowToken(bridge, address(0x1234));

        vm.startPrank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] memory slotData = _buildRecordedDepositSlotDataSingle();
        uint256[] memory publicInputs =
            _buildDepositBatchPublicInputs(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slotData));
        DepositBatchHashVerifier verifier = new DepositBatchHashVerifier(
            _computeDepositBatchPublicInputsHash(publicInputs)
        );
        bridge.setDepositBatchVerifier(address(verifier));
        bridge.batchAppend(proof, publicInputs, slotData);
        vm.stopPrank();

        assertEq(bridge.depositRoot(), bytes32(uint256(456)));
        assertEq(bridge.provedDepositCount(), 1);
    }
    function testBatchClaimWithdrawalTotalOverflowSkipsSlotWithoutConsumingNullifier() public {
        (Bridge bridge,, bytes32 withdrawalRoot) = _setupBatchClaimBridge();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 1;
        bytes32 nonce = bytes32(uint256(0xAB));

        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = address(token);
        uint256[] memory historicalTotals = new uint256[](1);
        historicalTotals[0] = type(uint256).max;
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(
            configuredTokens, _flowConfigs(1), historicalTotals, _tokenSetHash(configuredTokens), address(this)
        );
        assertEq(bridge.totalWithdrawalAmount(address(token)), type(uint256).max);

        BatchClaimItem[] memory items = _singleItem(BatchClaimItem(0, user, address(token), amount, nonce, 0));
        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, items);
        _setBatchClaimVerifier(bridge, publicInputs);

        uint256[8] memory proof;
        vm.prank(user);
        (uint8[] memory failedSlots, uint8[] memory reasons) = bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        assertEq(failedSlots.length, 1);
        assertEq(failedSlots[0], 0);
        assertEq(reasons[0], bridge.CLAIM_REASON_TOTAL_AMOUNT_OVERFLOW());
        assertEq(bridge.totalWithdrawalAmount(address(token)), type(uint256).max);
        assertFalse(bridge.claimedNullifiers(nonce));
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, 0);
    }

    function _publicInputsRoot(uint256[18] memory publicInputs) internal pure returns (bytes32 out) {
        for (uint256 j = 0; j < 8; ++j) {
            out |= bytes32(publicInputs[j] << ((7 - j) * 32));
        }
    }

    function testBatchClaimWithdrawalAcceptsKnownSubtreeRootAndRejectsUnknownRoot() public {
        (Bridge bridge, StateManager sm, bytes32 withdrawalRoot) = _setupBatchClaimBridge();
        assertTrue(withdrawalRoot != bytes32(0), "fixture subtree root must be nonzero");
        assertEq(withdrawalRoot, sm.withdrawalSubtreeRoot());
        assertTrue(sm.knownWithdrawalSubtreeRoots(withdrawalRoot));

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 knownNonce = bytes32(uint256(0xD1));
        bytes32 unknownNonce = bytes32(uint256(0xD2));

        BatchClaimItem[] memory knownItems = _singleItem(BatchClaimItem(0, user, address(token), amount, knownNonce, 0));
        (uint256[18] memory knownInputs, uint256[1088] memory knownSlotData) =
            _buildWithdrawalBatchClaimMulti(withdrawalRoot, knownItems);
        assertEq(_publicInputsRoot(knownInputs), withdrawalRoot, "encoded root must be the fixture subtree root");
        _setBatchClaimVerifier(bridge, knownInputs);

        uint256[8] memory proof;
        vm.prank(user);
        (uint8[] memory knownFailed, uint8[] memory knownReasons) =
            bridge.batchClaimWithdrawal(proof, knownInputs, knownSlotData);
        assertEq(knownFailed.length, 0);
        assertEq(knownReasons.length, 0);
        assertTrue(bridge.claimedNullifiers(knownNonce));
        assertEq(bridge.totalWithdrawalAmount(address(token)), amount);
        (address pendingToken, address pendingRecipient, uint256 pendingAmount, uint64 claimableAt) =
            bridge.pendingWithdrawals(knownNonce);
        assertEq(pendingToken, address(token));
        assertEq(pendingRecipient, user);
        assertEq(pendingAmount, amount);
        assertGt(uint256(claimableAt), 0);

        bytes32 unknownRoot = keccak256("unknown-withdrawal-subtree");
        assertFalse(sm.knownWithdrawalSubtreeRoots(unknownRoot));
        assertTrue(unknownRoot != sm.withdrawalSubtreeRoot());
        BatchClaimItem[] memory unknownItems =
            _singleItem(BatchClaimItem(0, user, address(token), amount, unknownNonce, 0));
        (uint256[18] memory unknownInputs, uint256[1088] memory unknownSlotData) =
            _buildWithdrawalBatchClaimMulti(unknownRoot, unknownItems);
        assertEq(_publicInputsRoot(unknownInputs), unknownRoot);
        _setBatchClaimVerifier(bridge, unknownInputs);

        vm.recordLogs();
        vm.prank(user);
        vm.expectRevert(Bridge.InvalidWithdrawalProof.selector);
        bridge.batchClaimWithdrawal(proof, unknownInputs, unknownSlotData);
        assertEq(vm.getRecordedLogs().length, 0, "unknown root reverts before registration events");
        assertTrue(bridge.claimedNullifiers(knownNonce));
        assertFalse(bridge.claimedNullifiers(unknownNonce));
        assertEq(bridge.totalWithdrawalAmount(address(token)), amount);
        (pendingToken, pendingRecipient, pendingAmount, claimableAt) = bridge.pendingWithdrawals(knownNonce);
        assertEq(pendingToken, address(token));
        assertEq(pendingRecipient, user);
        assertEq(pendingAmount, amount);
        assertGt(uint256(claimableAt), 0);
        (,, uint256 unknownPending,) = bridge.pendingWithdrawals(unknownNonce);
        assertEq(unknownPending, 0);
    }


    function testForceClaimWithdrawalTransferRevertKeepsPendingTotalAndNullifier() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        MockGnarkVerifier bootstrapVerifier = new MockGnarkVerifier();
        StateManager sm = _deployStateManager(provider);
        Router router = _deployRouter(provider);
        Bridge bridge = _deployBridge(provider, address(bootstrapVerifier), address(bootstrapVerifier));
        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(bootstrapVerifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        vm.stopPrank();
        RevertingTransferToken token = new RevertingTransferToken();
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(0xCC));

        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        (bytes32[9] memory depositProof, bytes32 depositRoot) = _mkTopProof(depositLeaf, 0);
        (bytes32[9] memory withdrawalProof, bytes32 withdrawalRoot) = _mkTopProof(bytes32(uint256(0x1234)), 0);
        vm.prank(owner);
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

        (uint256[18] memory publicInputs, uint256[1088] memory slotData) =
            _buildWithdrawalBatchClaimPublicInputsSingle(withdrawalProof[0], 0, user, address(token), amount, nonce, 0, 0);
        WithdrawalBatchHashVerifier verifier =
            new WithdrawalBatchHashVerifier(_computeWithdrawalBatchClaimPublicInputsHash(publicInputs));
        vm.prank(owner);
        bridge.setWithdrawalClaimVerifier(address(verifier));
        uint256[8] memory proof;
        vm.prank(user);
        bridge.batchClaimWithdrawal(proof, publicInputs, slotData);

        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = address(token);
        uint256[] memory historicalTotals = new uint256[](1);
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(configuredTokens, _flowConfigs(configuredTokens.length), historicalTotals, _tokenSetHash(configuredTokens), address(this));

        (address pendingToken, address pendingRecipient, uint256 pendingAmount, uint64 pendingClaimableAt) =
            bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, amount);
        assertEq(pendingRecipient, user);
        assertTrue(bridge.claimedNullifiers(nonce));
        uint256 totalBefore = bridge.totalWithdrawalAmount(address(token));

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "transfer rejected"));
        bridge.forceClaimWithdrawal(nonce);

        (address tokenAfter, address recipientAfter, uint256 amountAfter, uint64 claimableAtAfter) =
            bridge.pendingWithdrawals(nonce);
        assertEq(tokenAfter, pendingToken);
        assertEq(recipientAfter, pendingRecipient);
        assertEq(amountAfter, pendingAmount);
        assertEq(claimableAtAfter, pendingClaimableAt);
        assertEq(bridge.totalWithdrawalAmount(address(token)), totalBefore);
        assertTrue(bridge.claimedNullifiers(nonce));
    }
}
