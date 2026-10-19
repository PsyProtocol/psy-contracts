// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BridgeTest, DepositBatchHashVerifier} from "./Bridge.t.sol";
import {Bridge} from "../../src/Bridge.sol";
import {PackedDepositAppendAdapter} from "../../src/PackedDepositAppendAdapter.sol";

/// Exercises the unchanged Bridge checks and exact verifier public-input hash.
/// Cryptographic proof verification still requires a real-proof fork replay.
contract PackedDepositBridgeTest is BridgeTest {
    function packed(uint256[] memory pi, uint256[1312] memory slots) internal pure returns (bytes memory out) {
        out = new bytes(8684); // first 256 bytes are the zero test proof
        for (uint256 i; i < 795 + 1312; ++i) {
            uint256 word = i < 795 ? pi[i] : slots[i - 795];
            uint256 offset = 256 + i * 4;
            out[offset] = bytes1(uint8(word >> 24));
            out[offset + 1] = bytes1(uint8(word >> 16));
            out[offset + 2] = bytes1(uint8(word >> 8));
            out[offset + 3] = bytes1(uint8(word));
        }
    }

    function testPackedBridgePreservesVerifierHashRootAndCursor() public {
        (Bridge bridge,) = _setupBridgeSystem();
        PackedDepositAppendAdapter adapter = new PackedDepositAppendAdapter(address(bridge));
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        uint256[1312] memory slots = _buildRecordedDepositSlotDataSingle();
        uint256[] memory pi = _buildDepositBatchPublicInputs(
            EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slots)
        );
        DepositBatchHashVerifier verifier = new DepositBatchHashVerifier(_computeDepositBatchPublicInputsHash(pi));
        vm.prank(owner);
        bridge.setDepositBatchVerifier(address(verifier));
        bytes memory record = packed(pi, slots);
        uint256 before = gasleft();
        adapter.appendPackedBatches(record);
        emit log_named_uint("adapter + unchanged Bridge gas (1 deposit, hash-check verifier)", before - gasleft());
        assertEq(bridge.provedDepositCount(), 1);
        assertEq(bridge.depositRoot(), bytes32(uint256(456)));
        vm.expectRevert(Bridge.InvalidBatchRange.selector);
        adapter.appendPackedBatches(record);
    }

    function testPackedBridgeLaterInvalidRangeRollsBackFirstAppend() public {
        (Bridge bridge,) = _setupBridgeSystem();
        PackedDepositAppendAdapter adapter = new PackedDepositAppendAdapter(address(bridge));
        vm.prank(owner);
        bridge.recordDepositFromGateway(address(0x1234), bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(uint256(3)));
        uint256[1312] memory slots = _buildRecordedDepositSlotDataSingle();
        uint256[] memory pi = _buildDepositBatchPublicInputs(
            EMPTY_DEPOSIT_ROOT, bytes32(uint256(456)), 0, 1, _computeDepositBatchSlotDataCommit(slots)
        );
        bytes memory record = packed(pi, slots);
        vm.expectRevert(Bridge.InvalidBatchRange.selector);
        adapter.appendPackedBatches(bytes.concat(record, record));
        assertEq(bridge.provedDepositCount(), 0);
        assertEq(bridge.depositRoot(), EMPTY_DEPOSIT_ROOT);
    }
}
