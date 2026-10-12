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
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {AtomicBridgeFixture} from "./fixtures/AtomicBridgeFixture.sol";

contract RevertingTransferToken is MockERC20 {
    constructor() MockERC20("Revert", "RVT") {}

    function transfer(address, uint256) public pure override returns (bool) {
        revert("transfer rejected");
    }
}

contract BridgeTest is AtomicBridgeFixture {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    uint32 internal constant SENDER = 0;
    uint32 internal constant OTHER_SENDER = 7;
    uint32 internal constant TOKEN_ID = 1;
    uint32 internal constant OTHER_TOKEN_ID = 2;
    address internal constant TOKEN = address(0x1234);
    address internal constant OTHER_TOKEN = address(0x5678);

    function _defaultFlowConfig() internal pure returns (Bridge.TokenFlowConfig memory) {
        return Bridge.TokenFlowConfig({
            minDepositAmount: 1,
            depositCap: 1e30,
            smallWithdrawalMax: 1e18,
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
        _deployAtomic(owner, owner);
        bridge = atomicBridge;
        verifier = openingVerifier;
        MockERC20 mockToken = new MockERC20("Mock", "MOCK");
        vm.etch(TOKEN, address(mockToken).code);
        _configureFlowToken(bridge, TOKEN);
    }

    function _bridgeContractState(bytes32 root, uint256 provedCount, uint256 pendingCount)
        internal pure returns (Bridge.BridgeContractState memory)
    {
        return Bridge.BridgeContractState(root, provedCount, pendingCount);
    }

    function _key(uint32 sender, uint32 tokenId, bytes32 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(sender, tokenId, nonce));
    }

    function _openingDigest(bytes memory opening) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), opening));
    }

    function _pokeWord(bytes memory opening, uint256 word, uint256 value) internal pure {
        assembly ("memory-safe") {
            mstore(add(opening, add(32, mul(word, 32))), value)
        }
    }

    function _burn(uint8 chainIndex, uint32 userId, uint32 contractId, bytes32 nonce, address recipient, uint256 amount)
        internal pure returns (BridgeOpening.WithdrawalBurnRecord memory)
    {
        return BridgeOpening.WithdrawalBurnRecord(chainIndex, userId, contractId, nonce, recipient, amount);
    }

    function _applyBurns(BridgeOpening.WithdrawalBurnRecord[] memory records) internal returns (Opening memory a) {
        uint64 endId = manager.lastFinalizedCheckpointId() + 1;
        a = _opening(endId, bytes32(uint256(endId)), _currentRow(), new BridgeOpening.DepositLeaf[](0), records);
        vm.prank(owner);
        _apply(a);
    }

    function _register(address recipient, uint32 tokenId, uint256 amount, bytes32 nonce) internal returns (bytes32 key) {
        BridgeOpening.WithdrawalBurnRecord[] memory records = new BridgeOpening.WithdrawalBurnRecord[](1);
        records[0] = _burn(0, SENDER, tokenId, nonce, recipient, amount);
        _applyBurns(records);
        key = _key(SENDER, tokenId, nonce);
    }

    function testForceSetStateRestoresFieldsLeavesMappingsAndRetryIsNoOp() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        bytes32 recordedLeaf = bridge.depositLeafHashes(0);
        bytes32 nonce = bytes32(uint256(0xCA11));
        bytes32 key = _key(SENDER, TOKEN_ID, nonce);
        BridgeOpening.BridgeChainRow memory row = _currentRow();
        row.newDepositRoot = bytes32(uint256(0xCAFE));
        row.newCount = 1;
        BridgeOpening.WithdrawalBurnRecord[] memory records = new BridgeOpening.WithdrawalBurnRecord[](1);
        records[0] = _burn(0, SENDER, TOKEN_ID, nonce, user, 1);
        Opening memory a = _opening(1, bytes32(uint256(0xCAFE)), row, _recordedLeaf(), records);
        vm.prank(owner);
        _apply(a);
        assertEq(bridge.depositRoot(), bytes32(uint256(0xCAFE)));
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(bridge.pendingDepositCount(), 1);
        assertTrue(bridge.claimedWithdrawals(key));

        Bridge.BridgeContractState memory expected = _bridgeContractState(bytes32(uint256(0xCAFE)), 1, 1);
        Bridge.BridgeContractState memory target = _bridgeContractState(bytes32(uint256(0xBEEF)), 0, 0);

        vm.recordLogs();
        vm.prank(owner);
        bridge.forceSetState(expected, target);
        Vm.Log[] memory resetLogs = vm.getRecordedLogs();
        assertEq(resetLogs.length, 1);
        assertEq(resetLogs[0].topics[0], Bridge.ForceSetState.selector);

        assertEq(bridge.depositRoot(), target.depositRoot);
        assertEq(bridge.provedDepositCount(), target.provedDepositCount);
        assertEq(bridge.pendingDepositCount(), target.pendingDepositCount);
        assertEq(bridge.depositLeafHashes(0), recordedLeaf);
        assertTrue(bridge.claimedWithdrawals(key));
        (,, uint256 pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 1);

        vm.recordLogs();
        vm.prank(owner);
        bridge.forceSetState(expected, target);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testForceSetStateFailsClosedOnAuthCasAndInvariants() public {
        (Bridge bridge,) = _setupBridgeSystem();

        Bridge.BridgeContractState memory current = _bridgeContractState(EMPTY_DEPOSIT_ROOT, 0, 0);

        vm.prank(user);
        vm.expectRevert(Bridge.UnauthorizedBridgeAdmin.selector);
        bridge.forceSetState(current, current);

        Bridge.BridgeContractState memory stale = _bridgeContractState(bytes32(uint256(1)), 0, 0);
        Bridge.BridgeContractState memory target = _bridgeContractState(bytes32(uint256(2)), 0, 0);
        vm.prank(owner);
        vm.expectPartialRevert(Bridge.UnexpectedCurrentState.selector);
        bridge.forceSetState(stale, target);

        Bridge.BridgeContractState memory provedAbovePending = _bridgeContractState(bytes32(uint256(2)), 1, 0);
        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidForceSetState.selector);
        bridge.forceSetState(current, provedAbovePending);

        Bridge.BridgeContractState memory countIncrease = _bridgeContractState(bytes32(uint256(2)), 0, 1);
        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidForceSetState.selector);
        bridge.forceSetState(current, countIncrease);

        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.pendingDepositCount(), 0);
    }

    function testRecordDepositDisabled() public {
        (Bridge bridge,) = _setupBridgeSystem();

        MockERC20 token = new MockERC20("Mock", "MOCK");

        token.mint(user, 1000);

        vm.startPrank(user);
        token.approve(address(bridge), 400);
        vm.expectRevert(Bridge.DirectDepositDisabled.selector);
        bridge.recordDeposit(address(token), 400, bytes32(uint256(123)), bytes32(uint256(456)));
        vm.stopPrank();
    }

    function testRecordDepositFromGatewayRejectsZeroAmount() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        vm.expectRevert(Bridge.ZeroAmount.selector);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 0, bytes32(uint256(123)), bytes32(uint256(456)));
    }

    function _recordedLeaf() internal pure returns (BridgeOpening.DepositLeaf[] memory leaves) {
        leaves = new BridgeOpening.DepositLeaf[](1);
        leaves[0] = BridgeOpening.DepositLeaf(0, 0, bytes32(uint256(2)), TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(3)));
    }

    function _depositOpening(bytes32 oldRoot, bytes32 newRoot, uint32 oldCount, uint32 newCount, BridgeOpening.DepositLeaf[] memory leaves)
        internal view returns (Opening memory)
    {
        BridgeOpening.BridgeChainRow memory row = _currentRow();
        row.oldDepositRoot = oldRoot;
        row.newDepositRoot = newRoot;
        row.oldCount = oldCount;
        row.newCount = newCount;
        uint64 endId = manager.lastFinalizedCheckpointId() + 1;
        return _opening(endId, bytes32(uint256(endId)), row, leaves, new BridgeOpening.WithdrawalBurnRecord[](0));
    }

    function testClaimWithdrawalPaysStoredRecipientOnce() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20(TOKEN).mint(address(bridge), 123);
        bytes32 nonce = bytes32(uint256(1));
        bytes32 key = _register(user, TOKEN_ID, 123, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 0);
        assertTrue(bridge.claimedWithdrawals(key));

        vm.expectEmit(false, false, false, true, address(bridge));
        emit Bridge.WithdrawalSettled(1, key, user, 123);
        vm.prank(user);
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 123);
        assertEq(MockERC20(TOKEN).balanceOf(address(bridge)), 0);
        (,, uint256 pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 0);
        assertTrue(bridge.claimedWithdrawals(key));

        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, key));
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
    }

    function testWrongSenderTokenAndChainDoNotSettleTheScopedKey() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20(TOKEN).mint(address(bridge), 50);
        bytes32 nonce = bytes32(uint256(1));
        bytes32 key = _register(user, TOKEN_ID, 50, nonce);

        bytes32 wrongSender = _key(OTHER_SENDER, TOKEN_ID, nonce);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, wrongSender));
        bridge.claimPendingWithdrawal(OTHER_SENDER, TOKEN_ID, nonce);
        bytes32 wrongToken = _key(SENDER, OTHER_TOKEN_ID, nonce);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, wrongToken));
        bridge.claimPendingWithdrawal(SENDER, OTHER_TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 0);
        (,, uint256 pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 50);

        BridgeOpening.WithdrawalBurnRecord[] memory foreign = new BridgeOpening.WithdrawalBurnRecord[](1);
        foreign[0] = _burn(9, SENDER, TOKEN_ID, bytes32(uint256(2)), user, 1);
        uint64 endId = manager.lastFinalizedCheckpointId() + 1;
        Opening memory rejected = _opening(endId, bytes32(uint256(endId)), _currentRow(), new BridgeOpening.DepositLeaf[](0), foreign);
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        _apply(rejected);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertFalse(bridge.claimedWithdrawals(_key(SENDER, TOKEN_ID, bytes32(uint256(2)))));
        assertFalse(manager.appliedOpenings(_openingDigest(rejected.opening)));
    }

    function testSameNonceAcrossSenderAndTokenAreDistinctFullPayments() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20 other = new MockERC20("Other", "OTH");
        vm.etch(OTHER_TOKEN, address(other).code);
        _configureFlowToken(bridge, OTHER_TOKEN);
        MockERC20(TOKEN).mint(address(bridge), 40);
        MockERC20(OTHER_TOKEN).mint(address(bridge), 70);
        address second = address(0xBEEF);
        bytes32 nonce = bytes32(uint256(9));

        BridgeOpening.WithdrawalBurnRecord[] memory first = new BridgeOpening.WithdrawalBurnRecord[](2);
        first[0] = _burn(0, SENDER, TOKEN_ID, nonce, user, 10);
        first[1] = _burn(0, SENDER, OTHER_TOKEN_ID, nonce, user, 20);
        _applyBurns(first);
        BridgeOpening.WithdrawalBurnRecord[] memory secondScope = new BridgeOpening.WithdrawalBurnRecord[](1);
        secondScope[0] = _burn(0, OTHER_SENDER, TOKEN_ID, nonce, second, 30);
        _applyBurns(secondScope);

        bytes32 senderToken = _key(SENDER, TOKEN_ID, nonce);
        bytes32 senderOther = _key(SENDER, OTHER_TOKEN_ID, nonce);
        bytes32 otherSender = _key(OTHER_SENDER, TOKEN_ID, nonce);
        assertTrue(bridge.claimedWithdrawals(senderToken));
        assertTrue(bridge.claimedWithdrawals(senderOther));
        assertTrue(bridge.claimedWithdrawals(otherSender));

        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 10);
        (,, uint256 stillPending,) = bridge.scopedPendingWithdrawals(senderOther);
        assertEq(stillPending, 20);
        (,, uint256 otherPending,) = bridge.scopedPendingWithdrawals(otherSender);
        assertEq(otherPending, 30);

        bridge.claimPendingWithdrawal(SENDER, OTHER_TOKEN_ID, nonce);
        bridge.claimPendingWithdrawal(OTHER_SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(OTHER_TOKEN).balanceOf(user), 20);
        assertEq(MockERC20(TOKEN).balanceOf(second), 30);
        assertEq(MockERC20(TOKEN).balanceOf(address(bridge)), 0);
        assertEq(MockERC20(OTHER_TOKEN).balanceOf(address(bridge)), 50);
    }

    function testClaimWithdrawalRejectsRecipientHighBits() public {
        (Bridge bridge,) = _setupBridgeSystem();
        bytes32 nonce = bytes32(uint256(1));
        Opening memory a = _withdrawalOpening(user, TOKEN_ID, 1, nonce);
        uint256 recipientWord = 15 + 16 + 8;
        _pokeWord(a.opening, recipientWord, uint256(1) << 160);
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        _apply(a);
        assertFalse(bridge.claimedWithdrawals(_key(SENDER, TOKEN_ID, nonce)));
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertFalse(manager.appliedOpenings(_openingDigest(a.opening)));
    }

    function testZeroAmountAndZeroRecipientRejectTheWholeOpening() public {
        (Bridge bridge,) = _setupBridgeSystem();
        bytes32 nonce = bytes32(uint256(4));
        Opening memory zeroAmount = _withdrawalOpening(user, TOKEN_ID, 0, nonce);
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        _apply(zeroAmount);
        Opening memory zeroRecipient = _withdrawalOpening(address(0), TOKEN_ID, 1, nonce);
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        _apply(zeroRecipient);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertFalse(bridge.claimedWithdrawals(_key(SENDER, TOKEN_ID, nonce)));
        (,, uint256 pendingAmount,) = bridge.scopedPendingWithdrawals(_key(SENDER, TOKEN_ID, nonce));
        assertEq(pendingAmount, 0);
        assertFalse(manager.appliedOpenings(_openingDigest(zeroAmount.opening)));
        assertFalse(manager.appliedOpenings(_openingDigest(zeroRecipient.opening)));
    }

    function testRegisteredWithdrawalRemainsClaimableAfterLaterCheckpoint() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20(TOKEN).mint(address(bridge), 123);
        bytes32 nonce = bytes32(uint256(1));
        bytes32 key = _register(user, TOKEN_ID, 123, nonce);
        Opening memory later = _emptyOpening(2, bytes32(uint256(2)));
        vm.prank(owner);
        _apply(later);
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 123);
        assertEq(manager.lastFinalizedCheckpointId(), 2);
        assertTrue(bridge.claimedWithdrawals(key));
    }

    function testReplaySkipsConsumedKeyAndDoesNotAdvanceOrReverify() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20(TOKEN).mint(address(bridge), 25);
        bytes32 nonce = bytes32(uint256(5));
        Opening memory a = _withdrawalOpening(user, TOKEN_ID, 25, nonce);
        bytes32 key = _key(SENDER, TOKEN_ID, nonce);
        vm.prank(owner);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        (,, uint256 pendingAmount, uint64 claimableAt) = bridge.scopedPendingWithdrawals(key);

        openingVerifier.setShouldVerify(false);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit Bridge.WithdrawalSkipped(key, 1);
        vm.prank(owner);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        (,, uint256 pendingAfter, uint64 claimableAfter) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAfter, pendingAmount);
        assertEq(claimableAfter, claimableAt);

        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit Bridge.WithdrawalSkipped(key, 1);
        vm.prank(owner);
        _apply(a);
        assertEq(MockERC20(TOKEN).balanceOf(user), 25);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertTrue(bridge.claimedWithdrawals(key));
    }

    function testBatchClaimWithdrawalSnapshotsDelayAndSettlesFullAmountOnce() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 100;
        config.mediumWithdrawalMax = 200;
        config.totalWithdrawalCap = 200;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, TOKEN, config);
        uint256 amount = 250;
        bytes32 nonce = bytes32(uint256(88));
        bytes32 key = _key(SENDER, TOKEN_ID, nonce);
        MockERC20(TOKEN).mint(address(bridge), amount);

        _register(user, TOKEN_ID, amount, nonce);

        (,, uint256 pendingAmount, uint64 claimableAt) = bridge.scopedPendingWithdrawals(key);
        assertEq(MockERC20(TOKEN).balanceOf(user), 0);
        assertEq(pendingAmount, amount);
        assertEq(claimableAt, block.timestamp + 3_600);
        assertTrue(bridge.claimedWithdrawals(key));

        config.largeWithdrawalDelay = 7_200;
        _setFlowConfig(bridge, TOKEN, config);
        (,,, uint64 snapshottedClaimableAt) = bridge.scopedPendingWithdrawals(key);
        assertEq(snapshottedClaimableAt, claimableAt, "config update must not change an existing ETA");

        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotClaimable.selector, key, claimableAt));
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);

        address keeper = address(0xCAFE);
        vm.warp(claimableAt);
        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 4);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingClaimsPaused.selector, TOKEN));
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 0);
        vm.prank(keeper);
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), amount);
        (,, pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 0);
        assertEq(MockERC20(TOKEN).balanceOf(address(bridge)), 0);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, key));
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
    }

    function testEmptyOpeningStillRequiresProof() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Opening memory a = _emptyOpening(1, bytes32(uint256(1)));
        a.proof[0] = 0;
        vm.prank(owner);
        vm.expectRevert(StateManager.InvalidProof.selector);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertEq(bridge.provedDepositCount(), 0);
        assertFalse(manager.appliedOpenings(_openingDigest(a.opening)));
        a.proof[0] = 1;
        vm.prank(owner);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertTrue(manager.appliedOpenings(_openingDigest(a.opening)));
    }

    function testRegistrationPauseSkipsWithoutConsumingAndRetryRegisters() public {
        (Bridge bridge,) = _setupBridgeSystem();
        bytes32 nonce = bytes32(uint256(99));
        bytes32 key = _key(SENDER, TOKEN_ID, nonce);
        Opening memory a = _withdrawalOpening(user, TOKEN_ID, 123, nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 2);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit Bridge.WithdrawalSkipped(key, 2);
        vm.prank(owner);
        _apply(a);
        assertFalse(bridge.claimedWithdrawals(key));
        (,, uint256 pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 0);
        assertEq(manager.lastFinalizedCheckpointId(), 1);

        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 0);
        openingVerifier.setShouldVerify(false);
        vm.prank(owner);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertTrue(bridge.claimedWithdrawals(key));
        (,, pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 123);
    }

    function testPerTokenDepositLimitsIsolationAndDynamicConfigUpdate() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20 mockToken = new MockERC20("Mock B", "MOCKB");
        vm.etch(OTHER_TOKEN, address(mockToken).code);
        vm.etch(TOKEN, address(mockToken).code);

        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.minDepositAmount = 100;
        config.depositCap = 500;
        _setFlowConfig(bridge, TOKEN, config);
        _setFlowConfig(bridge, OTHER_TOKEN, config);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositBelowMinimum.selector, TOKEN, 99, 100));
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 99, bytes32(uint256(2)), bytes32(uint256(3)));

        MockERC20(TOKEN).mint(address(bridge), 501);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositCapExceeded.selector, TOKEN, 501, 500));
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 100, bytes32(uint256(4)), bytes32(uint256(5)));

        vm.prank(owner);
        bridge.recordDepositFromGateway(OTHER_TOKEN, bytes32(uint256(1)), 400, bytes32(uint256(6)), bytes32(uint256(7)));

        bytes32 oldHash = bridge.getTokenFlowConfigHash(TOKEN);
        config.depositCap = 1_000;
        _setFlowConfig(bridge, TOKEN, config);
        assertEq(bridge.getTokenFlowConfig(TOKEN).depositCap, 1_000);

        bytes32 currentHash = bridge.getTokenFlowConfigHash(TOKEN);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.StaleConfigHash.selector, oldHash, currentHash));
        bridge.setTokenFlowConfig(TOKEN, config, oldHash);
    }

    function testDepositExactBoundariesAndDepositCap() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.minDepositAmount = 100;
        config.depositCap = 1_000;
        _setFlowConfig(bridge, TOKEN, config);

        vm.startPrank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 100, bytes32(uint256(2)), bytes32(uint256(3)));
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 900, bytes32(uint256(4)), bytes32(uint256(5)));
        vm.stopPrank();

        MockERC20(TOKEN).mint(address(bridge), 1_001);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositCapExceeded.selector, TOKEN, 1_001, 1_000));
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 100, bytes32(uint256(10)), bytes32(uint256(11)));
    }

    function testInitializeWithdrawalTotalsValidatesInputsAndStoresAnyUint256Baseline() public {
        (Bridge bridge,) = _setupBridgeSystem();
        _configureFlowToken(bridge, OTHER_TOKEN);

        address[] memory tokens = new address[](2);
        tokens[0] = TOKEN;
        tokens[1] = OTHER_TOKEN;
        uint256[] memory totals = new uint256[](2);
        totals[0] = type(uint256).max;
        totals[1] = 42;
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, _tokenSetHash(tokens), address(this));
        assertEq(bridge.totalWithdrawalAmount(TOKEN), type(uint256).max);
        assertEq(bridge.totalWithdrawalAmount(OTHER_TOKEN), 42);
    }

    function testInitializeWithdrawalTotalsRejectsDuplicatesAndUnconfiguredTokens() public {
        (Bridge duplicateBridge,) = _setupBridgeSystem();
        address[] memory duplicateTokens = new address[](2);
        duplicateTokens[0] = TOKEN;
        duplicateTokens[1] = TOKEN;
        uint256[] memory duplicateTotals = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.DuplicateToken.selector, TOKEN));
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
        tokens[0] = TOKEN;
        uint256[] memory totals = new uint256[](1);
        totals[0] = 77;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.InvalidWithdrawalForceClaimExecutor.selector, address(0)));
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
                Bridge.WithdrawalTotalsTokenSetHashMismatch.selector, bytes32(uint256(1)), _tokenSetHash(tokens)
            )
        );
        badHashBridge.initializeWithdrawalTotals(tokens, _flowConfigs(tokens.length), totals, bytes32(uint256(1)), address(this));
        assertEq(badHashBridge.totalWithdrawalAmount(tokens[0]), 0);
        assertEq(badHashBridge.withdrawalForceClaimExecutor(), address(0));
        assertEq(badHashBridge.withdrawalTotalsTokenSetHash(), bytes32(0));
    }

    function testZeroDelaySmallAndMediumImmediatelyClaimableLargeDelayed() public {
        (Bridge bridge,) = _setupBridgeSystem();

        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 100;
        config.mediumWithdrawalMax = 200;
        config.totalWithdrawalCap = 200;
        config.smallWithdrawalDelay = 0;
        config.mediumWithdrawalDelay = 0;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, TOKEN, config);

        uint256 smallAmount = 50;
        uint256 mediumAmount = 150;
        uint256 largeAmount = 250;
        bytes32 smallNonce = bytes32(uint256(0x11));
        bytes32 mediumNonce = bytes32(uint256(0x22));
        bytes32 largeNonce = bytes32(uint256(0x33));
        MockERC20(TOKEN).mint(address(bridge), smallAmount + mediumAmount + largeAmount);

        _register(user, TOKEN_ID, smallAmount, smallNonce);
        _register(user, TOKEN_ID, mediumAmount, mediumNonce);
        _register(user, TOKEN_ID, largeAmount, largeNonce);

        bytes32 smallKey = _key(SENDER, TOKEN_ID, smallNonce);
        bytes32 mediumKey = _key(SENDER, TOKEN_ID, mediumNonce);
        bytes32 largeKey = _key(SENDER, TOKEN_ID, largeNonce);
        (,, uint256 smallPending, uint64 smallClaimableAt) = bridge.scopedPendingWithdrawals(smallKey);
        (,, uint256 mediumPending, uint64 mediumClaimableAt) = bridge.scopedPendingWithdrawals(mediumKey);
        (,, uint256 largePending, uint64 largeClaimableAt) = bridge.scopedPendingWithdrawals(largeKey);
        assertEq(smallPending, smallAmount);
        assertEq(mediumPending, mediumAmount);
        assertEq(largePending, largeAmount);
        assertEq(smallClaimableAt, block.timestamp, "zero-delay small tier must be immediately claimable");
        assertEq(mediumClaimableAt, block.timestamp, "zero-delay medium tier must be immediately claimable");
        assertEq(largeClaimableAt, block.timestamp + 3_600, "large tier delay must remain enforced");

        vm.prank(user);
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, smallNonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), smallAmount);
        vm.prank(user);
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, mediumNonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), smallAmount + mediumAmount);

        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotClaimable.selector, largeKey, largeClaimableAt));
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, largeNonce);

        vm.warp(largeClaimableAt);
        vm.prank(user);
        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, largeNonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), smallAmount + mediumAmount + largeAmount);
    }

    function testForceClaimWithdrawalBeforeDelayIsAdminOnlyPausedSafeAndOneShot() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 10;
        config.mediumWithdrawalMax = 20;
        config.totalWithdrawalCap = 20;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, TOKEN, config);
        MockERC20(TOKEN).mint(address(bridge), 30);

        bytes32 nonce = bytes32(uint256(0xFB));
        bytes32 key = _register(user, TOKEN_ID, 30, nonce);
        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = TOKEN;
        uint256[] memory historicalTotals = new uint256[](1);
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(
            configuredTokens, _flowConfigs(configuredTokens.length), historicalTotals, _tokenSetHash(configuredTokens), address(this)
        );

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Bridge.UnauthorizedWithdrawalForceClaimExecutor.selector, user));
        bridge.forceClaimWithdrawal(SENDER, TOKEN_ID, nonce);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.UnauthorizedWithdrawalForceClaimExecutor.selector, owner));
        bridge.forceClaimWithdrawal(SENDER, TOKEN_ID, nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 4);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingClaimsPaused.selector, TOKEN));
        bridge.forceClaimWithdrawal(SENDER, TOKEN_ID, nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 0);
        bridge.forceClaimWithdrawal(SENDER, TOKEN_ID, nonce);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, key));
        bridge.forceClaimWithdrawal(SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 30);
    }

    function testZeroSmallMediumDelayConfigAcceptedWithLargeDelay() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalDelay = 0;
        config.mediumWithdrawalDelay = 0;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, TOKEN, config);

        assertEq(
            bridge.getTokenFlowConfigHash(TOKEN),
            keccak256(abi.encode(TOKEN, config)),
            "zero small/medium delay with nonzero large delay must be a valid config"
        );
    }

    function testInvalidFlowConfigMatrixAndPauseFlagValidation() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Bridge.TokenFlowConfig memory config;

        config = _defaultFlowConfig();
        config.configured = false;
        _expectInvalidFlowConfig(bridge, TOKEN, config);
        config = _defaultFlowConfig();
        config.minDepositAmount = 0;
        _expectInvalidFlowConfig(bridge, TOKEN, config);
        config = _defaultFlowConfig();
        config.depositCap = config.minDepositAmount - 1;
        _expectInvalidFlowConfig(bridge, TOKEN, config);
        config = _defaultFlowConfig();
        config.smallWithdrawalMax = config.mediumWithdrawalMax + 1;
        _expectInvalidFlowConfig(bridge, TOKEN, config);
        config = _defaultFlowConfig();
        config.smallWithdrawalDelay = config.mediumWithdrawalDelay + 1;
        _expectInvalidFlowConfig(bridge, TOKEN, config);
        config = _defaultFlowConfig();
        config.mediumWithdrawalDelay = config.largeWithdrawalDelay + 1;
        _expectInvalidFlowConfig(bridge, TOKEN, config);

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
        PsyAddressesProvider addresses = PsyAddressesProvider(bridge.addressesProvider());
        PsyACLManager acl = PsyACLManager(addresses.getAddress(addresses.ACL_MANAGER_ID()));

        bytes32 guardianRole = acl.GUARDIAN_ROLE();
        vm.prank(owner);
        acl.grantRole(guardianRole, user);

        bytes32 configHash = bridge.getTokenFlowConfigHash(TOKEN);
        vm.prank(user);
        bridge.guardianPauseToken(TOKEN, 1);
        assertEq(bridge.getTokenFlowConfigHash(TOKEN), configHash, "pause state must not change config hash");
        (,, uint8 effectiveFlags) = bridge.getPauseFlags(TOKEN);
        assertEq(effectiveFlags, 1);

        vm.prank(user);
        bridge.guardianPauseToken(TOKEN, 0);
        (,, effectiveFlags) = bridge.getPauseFlags(TOKEN);
        assertEq(effectiveFlags, 1, "guardian cannot clear pause flags");

        vm.prank(user);
        vm.expectRevert(Bridge.UnauthorizedBridgeAdmin.selector);
        bridge.setTokenPauseFlags(TOKEN, 0);

        vm.prank(owner);
        bridge.setTokenPauseFlags(TOKEN, 0);
        (,, effectiveFlags) = bridge.getPauseFlags(TOKEN);
        assertEq(effectiveFlags, 0);
    }

    function testRescueRequiresBridgeAdminAndFullyPausedBridge() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20(TOKEN).mint(address(bridge), 100);

        vm.prank(user);
        vm.expectRevert(Bridge.UnauthorizedBridgeAdmin.selector);
        bridge.rescueERC20(TOKEN, user, 100);

        vm.prank(owner);
        vm.expectRevert(Bridge.BridgeNotFullyPaused.selector);
        bridge.rescueERC20(TOKEN, user, 100);

        vm.startPrank(owner);
        bridge.setGlobalPauseFlags(7);
        bridge.rescueERC20(TOKEN, user, 100);
        vm.stopPrank();
        assertEq(MockERC20(TOKEN).balanceOf(user), 100);
    }

    function testAtomicDepositRejectsRootMismatch() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        Opening memory a = _depositOpening(bytes32(uint256(123)), bytes32(uint256(456)), 0, 1, _recordedLeaf());
        vm.prank(owner);
        vm.expectRevert(StateManager.InvalidDepositMerkleProof.selector);
        _apply(a);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertFalse(manager.appliedOpenings(_openingDigest(a.opening)));
    }

    function testAtomicDepositRejectsBeyondPendingRange() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Opening memory a = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _recordedLeaf());
        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidBatchRange.selector);
        _apply(a);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testAtomicDepositRejectsDecreasingCount() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Opening memory a = _depositOpening(EMPTY_DEPOSIT_ROOT, EMPTY_DEPOSIT_ROOT, 1, 0, new BridgeOpening.DepositLeaf[](0));
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        _apply(a);
        assertEq(bridge.provedDepositCount(), 0);
    }

    function testAtomicDepositRejectsMalformedOpening() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Opening memory a = _emptyOpening(1, bytes32(uint256(1)));
        a.opening = bytes.concat(a.opening, bytes32(0));
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        _apply(a);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testAtomicDepositVerifierRejectionRollsBack() public {
        (Bridge bridge, MockGnarkVerifier verifier) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        Opening memory a = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _recordedLeaf());
        verifier.setShouldVerify(false);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "invalid proof"));
        _apply(a);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.pendingDepositCount(), 1);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertFalse(manager.appliedOpenings(_openingDigest(a.opening)));
    }

    function testAtomicDepositRejectsEachCustodyFieldMutation() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        for (uint256 field; field < 5; ++field) {
            BridgeOpening.DepositLeaf[] memory leaves = _recordedLeaf();
            if (field == 0) leaves[0].shieldAddress = bytes32(uint256(999));
            if (field == 1) leaves[0].token = address(0x9999);
            if (field == 2) leaves[0].l2TokenContractId = bytes32(uint256(999));
            if (field == 3) leaves[0].amount = 2;
            if (field == 4) leaves[0].noteCommitment = bytes32(uint256(999));
            Opening memory a = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, leaves);
            vm.prank(owner);
            vm.expectRevert(Bridge.DepositBatchCommitMismatch.selector);
            _apply(a);
            assertEq(bridge.provedDepositCount(), 0);
            assertEq(manager.lastFinalizedCheckpointId(), 0);
        }

        BridgeOpening.DepositLeaf[] memory foreignChain = _recordedLeaf();
        foreignChain[0].chainIndex = 9;
        Opening memory foreign = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, foreignChain);
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        _apply(foreign);

        BridgeOpening.DepositLeaf[] memory skippedIndex = _recordedLeaf();
        skippedIndex[0].absoluteIndex = 1;
        Opening memory unordered = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, skippedIndex);
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        _apply(unordered);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testAtomicDepositRejectsForgedRealCount() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Opening memory a = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 10, _recordedLeaf());
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        _apply(a);
        assertEq(bridge.provedDepositCount(), 0);
    }

    function testAtomicDepositOpeningDigestAndRootAdvance() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        Opening memory a = _depositOpening(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _recordedLeaf());
        bytes32 digest = _openingDigest(a.opening);
        vm.expectCall(address(openingVerifier), abi.encodeCall(MockGnarkVerifier.verifyProof, (a.proof, BridgeOpening.proofInputs(digest))));
        vm.prank(owner);
        _apply(a);
        assertEq(bridge.depositRoot(), bytes32(uint256(456)));
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(manager.depositSubtreeRoot(), bridge.depositRoot());
        assertEq(manager.depositCount(), 1);
        assertTrue(manager.appliedOpenings(digest));
    }

    function testUnknownTokenRollsBackEarlierDepositApplication() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        BridgeOpening.BridgeChainRow memory row = _currentRow();
        row.newDepositRoot = bytes32(uint256(456));
        row.newCount = 1;
        BridgeOpening.WithdrawalBurnRecord[] memory records = new BridgeOpening.WithdrawalBurnRecord[](1);
        records[0] = _burn(0, SENDER, 99, bytes32(uint256(1)), user, 1);
        Opening memory a = _opening(1, bytes32(uint256(1)), row, _recordedLeaf(), records);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.UnknownWithdrawalToken.selector, uint32(99)));
        _apply(a);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.pendingDepositCount(), 1);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertFalse(bridge.claimedWithdrawals(_key(SENDER, 99, bytes32(uint256(1)))));
        assertFalse(manager.appliedOpenings(_openingDigest(a.opening)));
    }

    function testUnconfiguredTokenSkipsWithoutConsumingSiblingOrReverting() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20(TOKEN).mint(address(bridge), 10);
        vm.prank(owner);
        bridge.recordDepositFromGateway(TOKEN, bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        bytes32 nonce = bytes32(uint256(8));
        bytes32 configuredKey = _key(SENDER, TOKEN_ID, nonce);
        bytes32 unconfiguredKey = _key(SENDER, OTHER_TOKEN_ID, nonce);
        BridgeOpening.BridgeChainRow memory row = _currentRow();
        row.newDepositRoot = bytes32(uint256(456));
        row.newCount = 1;
        BridgeOpening.WithdrawalBurnRecord[] memory records = new BridgeOpening.WithdrawalBurnRecord[](2);
        records[0] = _burn(0, SENDER, TOKEN_ID, nonce, user, 10);
        records[1] = _burn(0, SENDER, OTHER_TOKEN_ID, nonce, user, 10);
        Opening memory a = _opening(1, bytes32(uint256(1)), row, _recordedLeaf(), records);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit Bridge.WithdrawalSkipped(unconfiguredKey, 2);
        vm.prank(owner);
        _apply(a);

        assertEq(bridge.depositRoot(), bytes32(uint256(456)));
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertTrue(bridge.claimedWithdrawals(configuredKey));
        assertFalse(bridge.claimedWithdrawals(unconfiguredKey));
        (,, uint256 configuredPending,) = bridge.scopedPendingWithdrawals(configuredKey);
        (,, uint256 unconfiguredPending,) = bridge.scopedPendingWithdrawals(unconfiguredKey);
        assertEq(configuredPending, 10);
        assertEq(unconfiguredPending, 0);

        bridge.claimPendingWithdrawal(SENDER, TOKEN_ID, nonce);
        assertEq(MockERC20(TOKEN).balanceOf(user), 10);
        vm.expectRevert(abi.encodeWithSelector(Bridge.PendingWithdrawalNotFound.selector, unconfiguredKey));
        bridge.claimPendingWithdrawal(SENDER, OTHER_TOKEN_ID, nonce);
    }

    function testTotalOverflowSkipsWithoutConsumingAndRetryStaysUnconsumed() public {
        (Bridge bridge,) = _setupBridgeSystem();
        uint256 amount = 1;
        bytes32 nonce = bytes32(uint256(0xAB));
        bytes32 key = _key(SENDER, TOKEN_ID, nonce);

        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = TOKEN;
        uint256[] memory historicalTotals = new uint256[](1);
        historicalTotals[0] = type(uint256).max;
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(configuredTokens, _flowConfigs(configuredTokens.length), historicalTotals, _tokenSetHash(configuredTokens), address(this));
        assertEq(bridge.totalWithdrawalAmount(TOKEN), type(uint256).max);

        Opening memory a = _withdrawalOpening(user, TOKEN_ID, amount, nonce);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit Bridge.WithdrawalSkipped(key, 2);
        vm.prank(owner);
        _apply(a);
        assertEq(bridge.totalWithdrawalAmount(TOKEN), type(uint256).max);
        assertFalse(bridge.claimedWithdrawals(key));
        (,, uint256 pendingAmount,) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, 0);
        assertEq(manager.lastFinalizedCheckpointId(), 1);

        openingVerifier.setShouldVerify(false);
        vm.expectEmit(true, false, false, true, address(bridge));
        emit Bridge.WithdrawalSkipped(key, 2);
        vm.prank(owner);
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertFalse(bridge.claimedWithdrawals(key));
        assertEq(bridge.totalWithdrawalAmount(TOKEN), type(uint256).max);
    }

    function testForceClaimWithdrawalTransferRevertKeepsPendingTotalAndScopedClaim() public {
        (Bridge bridge,) = _setupBridgeSystem();
        RevertingTransferToken token = new RevertingTransferToken();
        vm.etch(TOKEN, address(token).code);
        _configureFlowToken(bridge, TOKEN);
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(0xCC));
        bytes32 key = _register(user, TOKEN_ID, amount, nonce);

        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = TOKEN;
        uint256[] memory historicalTotals = new uint256[](1);
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(configuredTokens, _flowConfigs(configuredTokens.length), historicalTotals, _tokenSetHash(configuredTokens), address(this));

        (address pendingToken, address pendingRecipient, uint256 pendingAmount, uint64 pendingClaimableAt) = bridge.scopedPendingWithdrawals(key);
        assertEq(pendingAmount, amount);
        assertEq(pendingRecipient, user);
        assertTrue(bridge.claimedWithdrawals(key));
        uint256 totalBefore = bridge.totalWithdrawalAmount(TOKEN);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "transfer rejected"));
        bridge.forceClaimWithdrawal(SENDER, TOKEN_ID, nonce);

        (address tokenAfter, address recipientAfter, uint256 amountAfter, uint64 claimableAtAfter) = bridge.scopedPendingWithdrawals(key);
        assertEq(tokenAfter, pendingToken);
        assertEq(recipientAfter, pendingRecipient);
        assertEq(amountAfter, pendingAmount);
        assertEq(claimableAtAfter, pendingClaimableAt);
        assertEq(bridge.totalWithdrawalAmount(TOKEN), totalBefore);
        assertTrue(bridge.claimedWithdrawals(key));
        assertEq(MockERC20(TOKEN).balanceOf(user), 0);
    }
}
