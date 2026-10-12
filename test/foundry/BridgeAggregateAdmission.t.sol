// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Bridge} from "../../src/Bridge.sol";
import {StateManager} from "../../src/StateManager.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";
import {AtomicBridgeFixture} from "./fixtures/AtomicBridgeFixture.sol";

import {OpeningFixturePayer} from "./fixtures/AtomicBridgeFixture.sol";
contract BridgeAggregateAdmissionTest is AtomicBridgeFixture {
    function rewardOpening() private view returns (Opening memory a) {
        a = _emptyOpening(1, bytes32(uint256(1)));
        bytes memory encoded = a.opening;
        assembly ("memory-safe") { mstore(add(encoded, 480), 1) }
        a.opening = bytes.concat(encoded, abi.encode(uint256(2), uint256(0), uint256(7), uint256(7), uint256(9)), _rootWords(bytes32(uint256(1))), _rootWords(bytes32(uint256(2))), abi.encode(uint256(1), address(15), uint256(5)));
    }

    function testRewardDispatchSharesFullOpeningReceipt() public {
        Opening memory a = rewardOpening();
        bytes32 digest = keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), a.opening));
        vm.recordLogs();
        _apply(a);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool observed;
        bool applied;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(openingPayer) && logs[i].topics[0] == OpeningFixturePayer.ObservedReward.selector) observed = true;
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == StateManager.RewardAggregateApplied.selector) {
                assertEq(logs[i].topics[1], digest);
                applied = true;
            }
        }
        assertTrue(observed);
        assertTrue(applied);
    }

    function testRewardCallbackCannotReenterPendingSettlement() public {
        Opening memory a = rewardOpening();
        openingPayer.setCallback(address(atomicBridge), abi.encodeCall(atomicBridge.claimPendingWithdrawal, (uint32(0), uint32(1), bytes32(uint256(9)))));
        _apply(a);
        assertFalse(openingPayer.callbackSucceeded());
        assertEq(openingPayer.callbackResult(), abi.encodeWithSelector(Bridge.InvalidWithdrawalProof.selector));
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function testChangedVerifierPolicyFailsClosedOnRetry() public {
        Opening memory a = _withdrawalOpening(address(15), 1, 5, bytes32(uint256(9)));
        _apply(a);
        openingVerifier.setWithdrawalTokenPolicy(0, 1, address(0x5678), bytes32(uint256(1)), 0, 32, 32);
        vm.expectRevert(Bridge.InvalidWithdrawalTokenPolicy.selector);
        _apply(a);
    }

    function testTokenPolicyInstallationRejectsUnboundAndOutOfRange() public {
        vm.expectRevert(Bridge.InvalidWithdrawalTokenPolicy.selector);
        atomicBridge.installWithdrawalToken(4, address(15), bytes32(uint256(4)), 0, 32, 32);
        vm.expectRevert(Bridge.InvalidWithdrawalTokenPolicy.selector);
        atomicBridge.installWithdrawalToken(4, address(15), bytes32(uint256(4)), type(uint32).max, 1, 32);
        vm.expectRevert(Bridge.InvalidWithdrawalTokenPolicy.selector);
        atomicBridge.installWithdrawalToken(1, address(0x1234), bytes32(uint256(1)), 0, 32, 32);
    }

    function testFailedTokenRegistrationDoesNotBlockNextRecord() public {
        configureToken();
        BridgeOpening.WithdrawalBurnRecord[] memory records = new BridgeOpening.WithdrawalBurnRecord[](2);
        records[0] = BridgeOpening.WithdrawalBurnRecord(0, 0, 2, bytes32(uint256(9)), address(15), 5);
        records[1] = BridgeOpening.WithdrawalBurnRecord(0, 1, 1, bytes32(uint256(9)), address(16), 5);
        Opening memory a = _opening(1, bytes32(uint256(1)), _currentRow(), new BridgeOpening.DepositLeaf[](0), records);
        _apply(a);
        bytes32 failed = keccak256(abi.encode(uint32(0), uint32(2), bytes32(uint256(9))));
        bytes32 succeeded = keccak256(abi.encode(uint32(1), uint32(1), bytes32(uint256(9))));
        assertFalse(atomicBridge.claimedWithdrawals(failed));
        assertTrue(atomicBridge.claimedWithdrawals(succeeded));
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function setUp() public { _deployAtomic(address(this), address(this)); }

    function configureToken() private {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x1234);
        Bridge.TokenFlowConfig[] memory limits = new Bridge.TokenFlowConfig[](1);
        limits[0] = Bridge.TokenFlowConfig(1, 1000, 100, 200, 1000, 10, 20, 30, true);
        atomicBridge.initializeFlowLimits(tokens, limits);
    }

    function testDepositAndWithdrawalDispatchRequireManager() public {
        BridgeOpening.BridgeChainRow memory row;
        vm.expectRevert(Bridge.OnlyStateManager.selector);
        atomicBridge.applyDepositAggregate(row, new BridgeOpening.DepositLeaf[](0), bytes32(0));
        vm.expectRevert(Bridge.OnlyStateManager.selector);
        atomicBridge.applyWithdrawals(new BridgeOpening.WithdrawalBurnRecord[](0));
        vm.expectRevert(Bridge.OnlyStateManager.selector);
        atomicBridge.registerWithdrawal(bytes32(0), address(0x1234), address(15), 1);
    }

    function testFailedRegistrationRetriesExactOpeningWithoutDeposits() public {
        Opening memory a = _withdrawalOpening(address(15), 1, 5, bytes32(uint256(9)));
        bytes32 key = keccak256(abi.encode(uint32(0), uint32(1), bytes32(uint256(9))));
        _apply(a);
        assertFalse(atomicBridge.claimedWithdrawals(key));
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        configureToken();
        openingVerifier.setShouldVerify(false);
        _apply(a);
        assertTrue(atomicBridge.claimedWithdrawals(key));
        (address token, address recipient, uint256 amount, uint64 claimableAt) = atomicBridge.scopedPendingWithdrawals(key);
        assertEq(token, address(0x1234));
        assertEq(recipient, address(15));
        assertEq(amount, 5);
        assertEq(claimableAt, block.timestamp + 10);
        assertEq(atomicBridge.totalWithdrawalAmount(address(0x1234)), 5);
        _apply(a);
        assertEq(atomicBridge.totalWithdrawalAmount(address(0x1234)), 5);
        assertEq(manager.lastFinalizedCheckpointId(), 1);
    }

    function testPausedRegistrationDoesNotBlockCheckpointOrConsumeKey() public {
        configureToken();
        atomicBridge.guardianPauseToken(address(0x1234), 2);
        Opening memory a = _withdrawalOpening(address(15), 1, 5, bytes32(uint256(9)));
        bytes32 key = keccak256(abi.encode(uint32(0), uint32(1), bytes32(uint256(9))));
        _apply(a);
        assertFalse(atomicBridge.claimedWithdrawals(key));
        assertEq(manager.lastFinalizedCheckpointId(), 1);
        assertEq(atomicBridge.totalWithdrawalAmount(address(0x1234)), 0);
        atomicBridge.setTokenPauseFlags(address(0x1234), 0);
        _apply(a);
        assertTrue(atomicBridge.claimedWithdrawals(key));
    }

    function testFailedProofCannotRegisterOrAcceptOpening() public {
        configureToken();
        Opening memory a = _withdrawalOpening(address(15), 1, 5, bytes32(uint256(9)));
        bytes32 key = keccak256(abi.encode(uint32(0), uint32(1), bytes32(uint256(9))));
        bytes32 digest = keccak256(bytes.concat(keccak256("PsyBridge/Opening/4"), a.opening));
        openingVerifier.setShouldVerify(false);
        vm.expectRevert(bytes("invalid proof"));
        _apply(a);
        assertFalse(atomicBridge.claimedWithdrawals(key));
        assertFalse(manager.appliedOpenings(digest));
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }

    function testSameNonceDifferentSenderDoesNotCollide() public {
        configureToken();
        Opening memory a = _withdrawalOpening(address(15), 1, 5, bytes32(uint256(9)));
        _apply(a);
        Opening memory b = _withdrawalOpening(address(16), 1, 5, bytes32(uint256(9)));
        bytes memory encoded = b.opening;
        assembly ("memory-safe") { mstore(add(encoded, 1088), 1) }
        _apply(b);
        bytes32 first = keccak256(abi.encode(uint32(0), uint32(1), bytes32(uint256(9))));
        bytes32 second = keccak256(abi.encode(uint32(1), uint32(1), bytes32(uint256(9))));
        assertTrue(atomicBridge.claimedWithdrawals(first));
        assertTrue(atomicBridge.claimedWithdrawals(second));
        assertEq(atomicBridge.totalWithdrawalAmount(address(0x1234)), 10);
    }

    function testUnknownTokenAndZeroAmountCannotAdvanceCheckpoint() public {
        Opening memory a = _withdrawalOpening(address(15), 1, 5, bytes32(uint256(9)));
        bytes memory encoded = a.opening;
        assembly ("memory-safe") { mstore(add(encoded, 1120), 999) }
        vm.expectRevert();
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
        a = _withdrawalOpening(address(15), 1, 0, bytes32(uint256(9)));
        vm.expectRevert();
        _apply(a);
        assertEq(manager.lastFinalizedCheckpointId(), 0);
    }
}
