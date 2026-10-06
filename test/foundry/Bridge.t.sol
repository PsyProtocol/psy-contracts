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
import {AtomicBridgeFixture} from "../fixtures/contracts/AtomicBridgeFixture.sol";


contract RevertingTransferToken is MockERC20 {
    constructor() MockERC20("Revert", "RVT") {}

    function transfer(address, uint256) public pure override returns (bool) {
        revert("transfer rejected");
    }
}

contract BridgeTest is AtomicBridgeFixture {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);

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
        verifier = depositVerifier;
        MockERC20 mockToken = new MockERC20("Mock", "MOCK");
        vm.etch(address(0x1234), address(mockToken).code);
        _configureFlowToken(bridge, address(0x1234));
    }

    function _bridgeContractState(bytes32 root, uint256 provedCount, uint256 pendingCount)
        internal pure returns (Bridge.BridgeContractState memory)
    {
        return Bridge.BridgeContractState(root, provedCount, pendingCount);
    }

    function testForceSetStateRestoresFieldsLeavesMappingsAndRetryIsNoOp() public {
        (Bridge bridge,) = _setupBridgeSystem();

        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        bytes32 recordedLeaf = bridge.depositLeafHashes(0);
        bytes32 claimedNonce = bytes32(uint256(0xCA11));
        vm.store(address(bridge), keccak256(abi.encode(claimedNonce, uint256(1))), bytes32(uint256(1)));
        assertTrue(bridge.claimedNullifiers(claimedNonce));

        Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, bytes32(uint256(0xCAFE)), 0, 1, _recordedLeaf());
        vm.prank(owner);
        _apply(w);
        assertEq(bridge.depositRoot(), bytes32(uint256(0xCAFE)));
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(bridge.pendingDepositCount(), 1);

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
        assertTrue(bridge.claimedNullifiers(claimedNonce));

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
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 0, bytes32(uint256(123)), bytes32(uint256(456)));
    }

    function _recordedLeaf() internal pure returns (BridgeOpening.DepositLeaf[] memory leaves) {
        leaves = new BridgeOpening.DepositLeaf[](1);
        leaves[0] = BridgeOpening.DepositLeaf(0, 0, bytes32(uint256(2)), address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(3)));
    }

    function _depositWindow(bytes32 oldRoot, bytes32 newRoot, uint32 oldCount, uint32 newCount, BridgeOpening.DepositLeaf[] memory leaves) internal view returns (Window memory) {
        return _window(manager.lastFinalizedCheckpointId() + 1, bytes32(uint256(manager.lastFinalizedCheckpointId() + 1)), BridgeOpening.DepositTransition(0, oldRoot, newRoot, oldCount, newCount), leaves, new BridgeOpening.WithdrawalLeaf[](0));
    }

    function _register(address recipient, address token, uint256 amount, bytes32 nonce) internal {
        Window memory w = _withdrawalWindow(recipient, token, amount, nonce);
        vm.prank(owner);
        _apply(w);
    }
    function testClaimWithdrawalWithProof() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        token.mint(address(bridge), 123);
        bytes32 nonce = bytes32(uint256(1));
        _register(user, address(token), 123, nonce);
        assertEq(token.balanceOf(user), 0);
        vm.prank(user);
        bridge.claimPendingWithdrawal(nonce);
        assertEq(token.balanceOf(user), 123);
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    function testClaimWithdrawalRejectsRecipientHighBits() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Window memory w = _withdrawalWindow(user, address(0x1234), 1, bytes32(uint256(1)));
        bytes memory opening = w.withdrawals;
        assembly ("memory-safe") { mstore(add(opening, 512), shl(160, 1)) }
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        _apply(w);
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(1))));
    }

    function testRegisteredWithdrawalRemainsClaimableAfterLaterCheckpoint() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        token.mint(address(bridge), 123);
        bytes32 nonce = bytes32(uint256(1));
        _register(user, address(token), 123, nonce);
        Window memory w = _emptyWindow(2, bytes32(uint256(2)));
        vm.prank(owner);
        _apply(w);
        bridge.claimPendingWithdrawal(nonce);
        assertEq(token.balanceOf(user), 123);
        assertEq(manager.lastFinalizedCheckpointId(), 2);
    }
    function testBatchClaimWithdrawalSnapshotsDelayAndSettlesFullAmountOnce() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20 token = new MockERC20("Mock", "MOCK");
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 100;
        config.mediumWithdrawalMax = 200;
        config.totalWithdrawalCap = 200;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, address(token), config);
        uint256 amount = 250;
        bytes32 nonce = bytes32(uint256(88));
        token.mint(address(bridge), amount);

        _register(user, address(token), amount, nonce);

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

    function testEmptyWithdrawalFamilyRequiresZeroProof() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        w.withdrawalProof[0] = 1;
        vm.prank(owner);
        vm.expectRevert(StateManager.InvalidProof.selector);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertEq(bridge.provedDepositCount(), 0);
        w.withdrawalProof[0] = 0;
        vm.prank(owner);
        _apply(w);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function testBatchClaimWithdrawalHonorsRegistrationPauseWithoutConsumingNullifier() public {
        (Bridge bridge,) = _setupBridgeSystem();
        address token = address(0x1234);
        bytes32 nonce = bytes32(uint256(99));
        Window memory w = _withdrawalWindow(user, token, 123, nonce);
        vm.prank(owner);
        bridge.setTokenPauseFlags(token, 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.WithdrawalRegistrationPaused.selector, token));
        _apply(w);
        assertFalse(bridge.claimedNullifiers(nonce));
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, 0);
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
        vm.expectRevert(abi.encodeWithSelector(Bridge.DepositCapExceeded.selector, tokenA, 501, 500));
        bridge.recordDepositFromGateway(tokenA, bytes32(uint256(1)), 100, bytes32(uint256(4)), bytes32(uint256(5)));

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
        bridge.recordDepositFromGateway(token, bytes32(uint256(1)), 100, bytes32(uint256(10)), bytes32(uint256(11)));
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
        (Bridge bridge,) = _setupBridgeSystem();

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

        _register(user, address(token), smallAmount, smallNonce);
        _register(user, address(token), mediumAmount, mediumNonce);
        _register(user, address(token), largeAmount, largeNonce);

        (,, uint256 smallPending, uint64 smallClaimableAt) = bridge.pendingWithdrawals(smallNonce);
        (,, uint256 mediumPending, uint64 mediumClaimableAt) = bridge.pendingWithdrawals(mediumNonce);
        (,, uint256 largePending, uint64 largeClaimableAt) = bridge.pendingWithdrawals(largeNonce);
        assertEq(smallPending, smallAmount);
        assertEq(mediumPending, mediumAmount);
        assertEq(largePending, largeAmount);
        assertEq(smallClaimableAt, block.timestamp, "zero-delay small tier must be immediately claimable");
        assertEq(mediumClaimableAt, block.timestamp, "zero-delay medium tier must be immediately claimable");
        assertEq(largeClaimableAt, block.timestamp + 3_600, "large tier delay must remain enforced");

        vm.prank(user);
        bridge.claimPendingWithdrawal(smallNonce);
        assertEq(token.balanceOf(user), smallAmount);
        vm.prank(user);
        bridge.claimPendingWithdrawal(mediumNonce);
        assertEq(token.balanceOf(user), smallAmount + mediumAmount);

        vm.expectRevert(
            abi.encodeWithSelector(Bridge.PendingWithdrawalNotClaimable.selector, largeNonce, largeClaimableAt)
        );
        bridge.claimPendingWithdrawal(largeNonce);

        vm.warp(largeClaimableAt);
        vm.prank(user);
        bridge.claimPendingWithdrawal(largeNonce);
        assertEq(token.balanceOf(user), smallAmount + mediumAmount + largeAmount);
    }

    function testForceClaimWithdrawalBeforeDelayIsAdminOnlyPausedSafeAndOneShot() public {
        (Bridge bridge,) = _setupBridgeSystem();
        MockERC20 token = new MockERC20("Mock", "MOCK");
        Bridge.TokenFlowConfig memory config = _defaultFlowConfig();
        config.smallWithdrawalMax = 10;
        config.mediumWithdrawalMax = 20;
        config.totalWithdrawalCap = 20;
        config.largeWithdrawalDelay = 3_600;
        _setFlowConfig(bridge, address(token), config);
        token.mint(address(bridge), 30);

        bytes32 nonce = bytes32(uint256(0xFB));
        _register(user, address(token), 30, nonce);
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

    function testAtomicDepositRejectsRootMismatch() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        Window memory w = _depositWindow(bytes32(uint256(123)), bytes32(uint256(456)), 0, 1, _recordedLeaf());
        vm.prank(owner);
        vm.expectRevert(Bridge.DepositRootMismatch.selector);
        _apply(w);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testAtomicDepositRejectsBeyondPendingRange() public {
        (Bridge bridge,) = _setupBridgeSystem();
        Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _recordedLeaf());
        vm.prank(owner);
        vm.expectRevert(Bridge.InvalidBatchRange.selector);
        _apply(w);
        assertEq(bridge.provedDepositCount(), 0);
    }

    function testAtomicDepositRejectsDecreasingCount() public {
        _setupBridgeSystem();
        Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, EMPTY_DEPOSIT_ROOT, 1, 0, new BridgeOpening.DepositLeaf[](0));
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        _apply(w);
    }

    function testAtomicDepositRejectsMalformedOpening() public {
        _setupBridgeSystem();
        Window memory w = _emptyWindow(1, bytes32(uint256(1)));
        w.deposits = bytes.concat(w.deposits, bytes32(0));
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        _apply(w);
    }

    function testAtomicDepositVerifierRejectionRollsBack() public {
        (Bridge bridge, MockGnarkVerifier verifier) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _recordedLeaf());
        verifier.setShouldVerify(false);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "invalid proof"));
        _apply(w);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.pendingDepositCount(), 1);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testAtomicDepositRejectsEachCustodyFieldMutation() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        for (uint256 field; field < 7; ++field) {
            BridgeOpening.DepositLeaf[] memory leaves = _recordedLeaf();
            if (field == 0) leaves[0].shieldAddress = bytes32(uint256(999));
            if (field == 1) leaves[0].token = address(0x9999);
            if (field == 2) leaves[0].l2TokenContractId = bytes32(uint256(999));
            if (field == 3) leaves[0].amount = 2;
            if (field == 4) leaves[0].noteCommitment = bytes32(uint256(999));
            if (field == 5) leaves[0].chainIndex = 9;
            if (field == 6) leaves[0].absoluteIndex = 1;
            Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, leaves);
            vm.prank(owner);
            vm.expectRevert(field < 5 ? Bridge.DepositBatchCommitMismatch.selector : BridgeOpening.InvalidOrdering.selector);
            _apply(w);
            assertEq(bridge.provedDepositCount(), 0);
            assertEq(manager.lastFinalizedCheckpointId(), 0);
        }
    }

    function testAtomicDepositRejectsForgedRealCount() public {
        _setupBridgeSystem();
        Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 10, _recordedLeaf());
        vm.prank(owner);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        _apply(w);
    }

    function testAtomicDepositOpeningDigestAndRootAdvance() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        Window memory w = _depositWindow(EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _recordedLeaf());
        BridgeOpening.DepositAggregateOpening memory deposit = BridgeOpening.readDepositAggregate(w.deposits, BridgeOpening.readConfig(networkConfig));
        vm.expectCall(address(depositVerifier), abi.encodeCall(MockGnarkVerifier.verifyProof, (w.depositProof, BridgeOpening.proofInputs(deposit.depositOpeningDigest))));
        vm.prank(owner);
        _apply(w);
        assertEq(bridge.depositRoot(), bytes32(uint256(456)));
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(manager.depositSubtreeRoot(), bridge.depositRoot());
        assertEq(manager.depositCount(), 1);
    }

    function testWithdrawalFailureRollsBackEarlierDepositApplication() public {
        (Bridge bridge,) = _setupBridgeSystem();
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        BridgeOpening.WithdrawalLeaf[] memory leaves = new BridgeOpening.WithdrawalLeaf[](2);
        leaves[0] = BridgeOpening.WithdrawalLeaf(0, 0, user, address(0x1234), 1, bytes32(uint256(1)));
        leaves[1] = BridgeOpening.WithdrawalLeaf(0, 0, user, address(0x9999), 1, bytes32(uint256(2)));
        Window memory w = _window(1, bytes32(uint256(1)), BridgeOpening.DepositTransition(0, EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1), _recordedLeaf(), leaves);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Bridge.TokenNotConfigured.selector, address(0x9999)));
        _apply(w);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.pendingDepositCount(), 1);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        assertFalse(bridge.claimedNullifiers(bytes32(uint256(1))));
    }
    function testBatchClaimWithdrawalTotalOverflowLeavesTotalMaxAndNoNullifierOrPending() public {
        (Bridge bridge,) = _setupBridgeSystem();

        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        uint256 amount = 1;
        bytes32 nonce = bytes32(uint256(0xAB));


        address[] memory configuredTokens = new address[](1);
        configuredTokens[0] = address(token);
        uint256[] memory historicalTotals = new uint256[](1);
        historicalTotals[0] = type(uint256).max;
        vm.prank(owner);
        bridge.initializeWithdrawalTotals(configuredTokens, _flowConfigs(configuredTokens.length), historicalTotals, _tokenSetHash(configuredTokens), address(this));
        assertEq(bridge.totalWithdrawalAmount(address(token)), type(uint256).max);

        Window memory w = _withdrawalWindow(user, address(token), amount, nonce);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                Bridge.TotalWithdrawalAmountOverflow.selector, address(token), type(uint256).max, amount
            )
        );
        _apply(w);

        assertEq(bridge.totalWithdrawalAmount(address(token)), type(uint256).max);
        assertFalse(bridge.claimedNullifiers(nonce));
        (,, uint256 pendingAmount,) = bridge.pendingWithdrawals(nonce);
        assertEq(pendingAmount, 0);
    }

    function testForceClaimWithdrawalTransferRevertKeepsPendingTotalAndNullifier() public {
        (Bridge bridge,) = _setupBridgeSystem();
        RevertingTransferToken token = new RevertingTransferToken();
        _configureFlowToken(bridge, address(token));
        uint256 amount = 123;
        bytes32 nonce = bytes32(uint256(0xCC));

        _register(user, address(token), amount, nonce);

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
