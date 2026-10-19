// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PackedDepositAppendAdapter} from "../../src/PackedDepositAppendAdapter.sol";

contract PackedDepositReceiver {
    bytes32[] internal expected;
    uint256 public received;
    error WrongRecord();
    error RejectedRecord();
    uint256 public rejectAt = type(uint256).max;

    function expectRecord(bytes32 hash) external { expected.push(hash); }
    function reject(uint256 index) external { rejectAt = index; }

    function batchAppend(uint256[8] calldata proof, uint256[] calldata inputs, uint256[1312] calldata slots) external {
        if (received == rejectAt) revert RejectedRecord();
        if (received >= expected.length || keccak256(abi.encode(proof, inputs, slots)) != expected[received]) {
            revert WrongRecord();
        }
        ++received;
    }
}

contract PackedDepositAppendAdapterTest is Test {
    PackedDepositReceiver internal receiver;
    PackedDepositAppendAdapter internal adapter;

    function setUp() public {
        receiver = new PackedDepositReceiver();
        adapter = new PackedDepositAppendAdapter(address(receiver));
    }

    function fixture(uint256 seed) internal returns (bytes memory record) {
        uint256[8] memory proof;
        uint256[] memory inputs = new uint256[](795);
        uint256[1312] memory slots;
        record = new bytes(8684);
        for (uint256 i; i < 8; ++i) {
            proof[i] = uint256(keccak256(abi.encode(seed, i)));
            assembly ("memory-safe") { mstore(add(add(record, 32), mul(i, 32)), mload(add(proof, mul(i, 32)))) }
        }
        for (uint256 i; i < 795 + 1312; ++i) {
            uint32 word = uint32(uint256(keccak256(abi.encode(seed, i + 8))));
            if (i < 795) inputs[i] = word;
            else slots[i - 795] = word;
            uint256 start = 256 + i * 4;
            record[start] = bytes1(uint8(word >> 24));
            record[start + 1] = bytes1(uint8(word >> 16));
            record[start + 2] = bytes1(uint8(word >> 8));
            record[start + 3] = bytes1(uint8(word));
        }
        receiver.expectRecord(keccak256(abi.encode(proof, inputs, slots)));
    }

    function testPackedSingleRecordKeepsEveryWordAndFullProofCoordinates() public {
        bytes memory record = fixture(1);
        adapter.appendPackedBatches(record);
        assertEq(receiver.received(), 1);
        assertEq(adapter.BRIDGE(), address(receiver));
    }

    function testPackedThreeDistinctRecordsKeepOrder() public {
        bytes memory records = bytes.concat(fixture(1), fixture(2), fixture(3));
        adapter.appendPackedBatches(records);
        assertEq(receiver.received(), 3);
    }

    function testPackedFourteenRecordsFitSafeCalldataBudget() public {
        bytes memory records;
        for (uint256 i; i < 14; ++i) records = bytes.concat(records, fixture(i));
        bytes memory callData = abi.encodeCall(PackedDepositAppendAdapter.appendPackedBatches, (records));
        assertEq(callData.length, 121668);
        assertLe(callData.length, 120 * 1024);
        adapter.appendPackedBatches(records);
        assertEq(receiver.received(), 14);
    }

    function testPackedTooManyRecordsRejectBeforeAnyBridgeCall() public {
        bytes memory records = new bytes(8684 * 15);
        vm.expectRevert(PackedDepositAppendAdapter.TooManyBatches.selector);
        adapter.appendPackedBatches(records);
        assertEq(receiver.received(), 0);
    }

    function testPackedEmptyRejected() public {
        vm.expectRevert(PackedDepositAppendAdapter.InvalidPackedLength.selector);
        adapter.appendPackedBatches("");
    }

    function testPackedTrailingBytesRejected() public {
        bytes memory record = bytes.concat(fixture(7), hex"00");
        vm.expectRevert(PackedDepositAppendAdapter.InvalidPackedLength.selector);
        adapter.appendPackedBatches(record);
    }

    function testPackedTruncationRejected() public {
        bytes memory record = new bytes(8683);
        vm.expectRevert(PackedDepositAppendAdapter.InvalidPackedLength.selector);
        adapter.appendPackedBatches(record);
    }

    function testPackedLaterRevertRollsBackEarlierRecord() public {
        bytes memory records = bytes.concat(fixture(1), fixture(2));
        receiver.reject(1);
        vm.expectRevert(PackedDepositReceiver.RejectedRecord.selector);
        adapter.appendPackedBatches(records);
        assertEq(receiver.received(), 0);
    }

    function testFuzzPackedEveryByteMutationChangesRestoredRecord(uint256 position) public {
        bytes memory record = fixture(8);
        position = bound(position, 0, record.length - 1);
        record[position] = bytes1(uint8(record[position]) ^ 1);
        vm.expectRevert(PackedDepositReceiver.WrongRecord.selector);
        adapter.appendPackedBatches(record);
    }

    function testPackedInvalidBridgeRejected() public {
        vm.expectRevert(PackedDepositAppendAdapter.InvalidBridge.selector);
        new PackedDepositAppendAdapter(address(0));
        vm.expectRevert(PackedDepositAppendAdapter.InvalidBridge.selector);
        new PackedDepositAppendAdapter(address(0x1234));
    }

    function testPackedRejectsNativeValue() public {
        bytes memory record = fixture(1);
        (bool success,) = address(adapter).call{value: 1}(abi.encodeCall(adapter.appendPackedBatches, (record)));
        assertFalse(success);
        assertEq(receiver.received(), 0);
        assertEq(address(adapter).balance, 0);
    }
}
