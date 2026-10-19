// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPackedDepositBridge {
    function batchAppend(
        uint256[8] calldata proof,
        uint256[] calldata publicInputs,
        uint256[1312] calldata slotData
    ) external;
}

/// @notice Lossless transport adapter for the existing 32-deposit Bridge ABI.
/// @dev No proofs are aggregated and no Bridge validation is bypassed. Each
/// record contains 8 full-width proof coordinates, 795 big-endian uint32 public
/// input words, and 1312 big-endian uint32 slot words, in their original order.
contract PackedDepositAppendAdapter {
    address public immutable BRIDGE;
    uint256 public constant PUBLIC_INPUT_WORDS = 795;
    uint256 public constant SLOT_DATA_WORDS = 1312;
    uint256 public constant RECORD_BYTES = 8 * 32 + (PUBLIC_INPUT_WORDS + SLOT_DATA_WORDS) * 4;
    uint256 public constant MAX_BATCHES = 14;

    error InvalidBridge();
    error InvalidPackedLength();
    error TooManyBatches();

    constructor(address bridge) {
        if (bridge == address(0) || bridge.code.length == 0) revert InvalidBridge();
        BRIDGE = bridge;
    }

    /// @notice Execute consecutive original Bridge calls atomically.
    /// @dev This contract accepts no ETH, holds no allowance, and has no admin.
    /// The Bridge itself enforces the proof, leaf commitments, cursor and roots.
    function appendPackedBatches(bytes calldata batches) external {
        if (batches.length == 0 || batches.length % RECORD_BYTES != 0) revert InvalidPackedLength();
        uint256 count = batches.length / RECORD_BYTES;
        if (count > MAX_BATCHES) revert TooManyBatches();

        // Allocate once and reuse across records, bounding memory consumption.
        uint256[8] memory proof;
        uint256[] memory publicInputs = new uint256[](PUBLIC_INPUT_WORDS);
        uint256[1312] memory slotData;
        for (uint256 record; record < count; ++record) {
            uint256 offset = record * RECORD_BYTES;
            assembly ("memory-safe") {
                let src := add(batches.offset, offset)
                for { let i := 0 } lt(i, 8) { i := add(i, 1) } {
                    mstore(add(proof, mul(i, 32)), calldataload(add(src, mul(i, 32))))
                }
                src := add(src, 256)
                for { let i := 0 } lt(i, 795) { i := add(i, 1) } {
                    mstore(add(add(publicInputs, 32), mul(i, 32)), shr(224, calldataload(add(src, mul(i, 4)))))
                }
                src := add(src, 3180)
                for { let i := 0 } lt(i, 1312) { i := add(i, 1) } {
                    mstore(add(slotData, mul(i, 32)), shr(224, calldataload(add(src, mul(i, 4)))))
                }
            }
            IPackedDepositBridge(BRIDGE).batchAppend(proof, publicInputs, slotData);
        }
    }
}
