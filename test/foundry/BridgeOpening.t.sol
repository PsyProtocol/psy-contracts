// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";

contract BridgeOpeningHarness {
    function readDepositAggregate(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readDepositAggregate(opening, BridgeOpening.readConfig(config)).depositOpeningDigest;
    }
    function readWithdrawalAggregate(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readWithdrawalAggregate(opening, BridgeOpening.readConfig(config)).openingDigest;
    }
    function readRewardAggregate(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readRewardAggregate(opening, BridgeOpening.readConfig(config)).openingDigest;
    }
    function readInclusionAggregateHeader(bytes calldata headerBytes) external pure returns (BridgeOpening.InclusionAggregateHeader memory) {
        return BridgeOpening.readInclusionAggregateHeader(headerBytes);
    }
    function inclusionHeaderDigest(bytes calldata headerBytes) external pure returns (bytes32) {
        return BridgeOpening.inclusionHeaderDigest(headerBytes);
    }
    function inclusionProofInputs(bytes calldata headerBytes) external pure returns (uint256[6] memory) {
        return BridgeOpening.inclusionProofInputs(headerBytes);
    }
    function verifyClaimPath(BridgeOpening.InclusionAggregateHeader memory header, uint32 localOrdinal, bytes32 leafCommit, bytes32[] memory siblings) external pure returns (bytes32) {
        return BridgeOpening.verifyClaimPath(header, localOrdinal, leafCommit, siblings);
    }
    function readWithdrawalLeaf(bytes calldata body) external pure returns (BridgeOpening.WithdrawalLeaf memory) {
        return BridgeOpening.readWithdrawalLeaf(body);
    }
    function withdrawalLeafCommit(bytes calldata body) external pure returns (bytes32) {
        return BridgeOpening.withdrawalLeafCommit(body);
    }
    function readSourceCheckpointRewardLeaf(bytes calldata body) external pure returns (BridgeOpening.SourceCheckpointRewardLeaf memory) {
        return BridgeOpening.readSourceCheckpointRewardLeaf(body);
    }
    function sourceCheckpointRewardLeafCommit(bytes calldata body) external pure returns (bytes32) {
        return BridgeOpening.sourceCheckpointRewardLeafCommit(body);
    }
    function readWindowFinalizationOpening(bytes calldata config, bytes calldata opening, bytes32 depositOpeningDigest) external pure returns (BridgeOpening.WindowFinalizationOpening memory) {
        return BridgeOpening.readWindowFinalizationOpening(opening, BridgeOpening.readConfig(config), depositOpeningDigest);
    }
}

contract BridgeOpeningTest is Test {
    BridgeOpeningHarness private harness = new BridgeOpeningHarness();

    function domain(string memory label) private pure returns (bytes32) {
        return keccak256(bytes.concat(bytes("PsyBridge/TwoArtifact/1/"), bytes(label)));
    }
    function configBytes() private pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(uint256(1), uint256(0), uint256(524288), bytes32(uint256(7)), uint256(1)),
            abi.encode(uint256(1), uint256(1), address(11), address(12), uint256(0), uint256(1), uint256(2), uint256(3), uint256(4)),
            abi.encode(uint256(1), address(13), address(14), uint256(1), uint256(18), uint256(0), uint256(100), uint256(1024), uint256(1024), uint256(1024))
        );
    }
    function depositOpening() private pure returns (bytes memory) {
        bytes32 configHash = keccak256(bytes.concat(domain("Config"), configBytes()));
        bytes memory end = abi.encode(uint256(0), uint256(1), uint256(2), uint256(3), uint256(4));
        bytes memory starts = abi.encode(uint256(1), uint256(1), uint256(0), uint256(1), uint256(2), uint256(3), uint256(4));
        bytes memory deposits = abi.encode(uint256(1), uint256(1), uint256(5), uint256(6), uint256(7), uint256(8), uint256(5), uint256(6), uint256(7), uint256(8), uint256(0), uint256(0));
        bytes32 windowId = keccak256(bytes.concat(domain("Window"), configHash, end, starts, deposits));
        return bytes.concat(abi.encode(configHash, windowId), end, starts, deposits, abi.encode(uint256(0)));
    }
    function openingAggregate(bytes memory records) private pure returns (bytes memory) {
        bytes memory a = depositOpening();
        bytes memory header = new bytes(224);
        for (uint256 i; i < 224; ++i) header[i] = a[i];
        return bytes.concat(header, records);
    }
    function withdrawalOpening(bytes memory records) private pure returns (bytes memory) {
        return openingAggregate(bytes.concat(abi.encode(uint256(1), uint256(9), uint256(10), uint256(11), uint256(12)), records));
    }
    function replaceWord(bytes memory body, uint256 index, uint256 value) private pure returns (bytes memory) {
        assembly ("memory-safe") { mstore(add(add(body, 32), mul(index, 32)), value) }
        return body;
    }
    function testEmptyFamiliesUseDistinctDomains() public view {
        bytes memory a = depositOpening();
        bytes memory projection = new bytes(a.length - 32);
        for (uint256 i; i < projection.length; ++i) projection[i] = a[i];
        bytes32 emptyDeposit = keccak256(abi.encode(domain("Empty"), uint256(1), uint256(0)));
        bytes32 expectedDepositOpeningDigest = keccak256(bytes.concat(domain("A"), projection, abi.encode(uint256(0), uint256(0), emptyDeposit)));
        assertEq(harness.readDepositAggregate(configBytes(), a), expectedDepositOpeningDigest);
        bytes memory emptyOpening = openingAggregate(abi.encode(uint256(0)));
        bytes32 expectedW = keccak256(abi.encodePacked(domain("WithdrawalBatch"), withdrawalOpening(abi.encode(uint256(0)))));
        bytes32 expectedR = keccak256(abi.encodePacked(domain("RewardBatch"), emptyOpening));
        assertEq(harness.readWithdrawalAggregate(configBytes(), withdrawalOpening(abi.encode(uint256(0)))), expectedW);
        assertEq(harness.readRewardAggregate(configBytes(), openingAggregate(abi.encode(uint256(0)))), expectedR);
    }
    function testRejectsTrailingOpeningWord() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readDepositAggregate(configBytes(), bytes.concat(depositOpening(), abi.encode(uint256(0))));
    }
    function testRejectsTruncatedFullOpening() public {
        bytes memory a = depositOpening();
        assembly ("memory-safe") { mstore(a, sub(mload(a), 32)) }
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readDepositAggregate(configBytes(), a);
    }
    function testRejectsNoncanonicalFelt() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readDepositAggregate(configBytes(), replaceWord(depositOpening(), 3, 18446744069414584321));
    }
    function testRejectsDifferentBridgeIdentity() public {
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readDepositAggregate(replaceWord(configBytes(), 2, 524289), depositOpening());
    }
    function testRejectsOmittedConfiguredChain() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readDepositAggregate(configBytes(), replaceWord(depositOpening(), 7, 0));
    }
    function testRejectsAddressHighBits() public {
        bytes memory withdrawal = abi.encode(uint256(1), uint256(1), uint256(7), (uint256(1) << 160) | 15, uint256(0), uint256(1), bytes32(uint256(4)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readWithdrawalAggregate(configBytes(), withdrawalOpening(withdrawal));
    }
    function testRejectsDuplicateNonceWithDifferentRecipient() public {
        bytes memory withdrawals = bytes.concat(abi.encode(uint256(2)),
            abi.encode(uint256(1), uint256(7), address(15), address(0), uint256(1), bytes32(uint256(4))),
            abi.encode(uint256(1), uint256(8), address(16), address(0), uint256(1), bytes32(uint256(4))));
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        harness.readWithdrawalAggregate(configBytes(), withdrawalOpening(withdrawals));
    }
    function testRejectsAmountAtFieldModulus() public {
        bytes memory withdrawal = abi.encode(uint256(1), uint256(1), uint256(7), address(15), address(0), uint256(18446744069414584321), bytes32(uint256(4)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readWithdrawalAggregate(configBytes(), withdrawalOpening(withdrawal));
    }
    function testRejectsRewardOutsideGutaSubtree() public {
        bytes memory rewards = abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(1), uint256(4), address(15));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readRewardAggregate(configBytes(), openingAggregate(rewards));
    }
    function testRejectsRewardNullifierRelabeling() public {
        bytes memory rewards = abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(0), uint256(4), address(15));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readRewardAggregate(configBytes(), openingAggregate(rewards));
    }
    function testRejectsAggregateTrailingWord() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readWithdrawalAggregate(configBytes(), withdrawalOpening(abi.encode(uint256(0), uint256(0))));
    }
    function testRejectsAggregateCapacityOverflow() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readWithdrawalAggregate(configBytes(), withdrawalOpening(abi.encode(uint256(1025))));
    }
    function testRejectsAggregateNoncanonicalRoot() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readRewardAggregate(configBytes(), replaceWord(openingAggregate(abi.encode(uint256(0))), 3, 18446744069414584321));
    }
    function testRejectsAggregateWrongConfiguration() public {
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readRewardAggregate(configBytes(), replaceWord(openingAggregate(abi.encode(uint256(0))), 0, 99));
    }
    function testFullCapacityWithdrawalAggregate() public view {
        bytes memory records = new bytes(32 * (1 + 1024 * 6));
        replaceWord(records, 0, 1024);
        for (uint256 i; i < 1024; ++i) {
            uint256 word = 1 + i * 6;
            replaceWord(records, word, 1);
            replaceWord(records, word + 1, 7);
            replaceWord(records, word + 2, uint256(uint160(address(15))));
            replaceWord(records, word + 3, 0);
            replaceWord(records, word + 4, 1);
            replaceWord(records, word + 5, i);
        }
        bytes memory body = withdrawalOpening(records);
        BridgeOpening.WithdrawalAggregateOpening memory decoded = BridgeOpening.readWithdrawalAggregate(body, BridgeOpening.readConfig(configBytes()));
        assertEq(decoded.withdrawals[1023].nonce, bytes32(uint256(1023)));
        assertEq(harness.readWithdrawalAggregate(configBytes(), body), keccak256(abi.encodePacked(domain("WithdrawalBatch"), body)));
    }
    function testRewardStatementBindsCompleteCanonicalOpening() public view {
        bytes memory body = openingAggregate(abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(0), uint256(3), address(15)));
        assertEq(harness.readRewardAggregate(configBytes(), body), keccak256(abi.encodePacked(domain("RewardBatch"), body)));
        bytes32 previous = harness.readRewardAggregate(configBytes(), body);
        body = replaceWord(body, 13, uint256(uint160(address(16))));
        assertNotEq(harness.readRewardAggregate(configBytes(), body), previous);
    }
    function testRejectsWithdrawalWrongChainCount() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readWithdrawalAggregate(configBytes(), replaceWord(withdrawalOpening(abi.encode(uint256(0))), 7, 0));
    }
    function testRejectsWithdrawalNoncanonicalEndpoint() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readWithdrawalAggregate(configBytes(), replaceWord(withdrawalOpening(abi.encode(uint256(0))), 8, 18446744069414584321));
    }
    function testWithdrawalStatementBindsEndpointVector() public view {
        bytes memory body = withdrawalOpening(abi.encode(uint256(0)));
        bytes32 previous = harness.readWithdrawalAggregate(configBytes(), body);
        body = replaceWord(body, 8, 10);
        assertNotEq(harness.readWithdrawalAggregate(configBytes(), body), previous);
        assertEq(harness.readWithdrawalAggregate(configBytes(), body), keccak256(abi.encodePacked(domain("WithdrawalBatch"), body)));
    }
    uint256 private constant CLAIM_TREE_MAX_CAPACITY = 131072;
    bytes32 private constant MARKER = bytes32(uint256(12));

    function be32(uint32 value) private pure returns (bytes memory) {
        return abi.encodePacked(value);
    }
    function be64(uint64 value) private pure returns (bytes memory) {
        return abi.encodePacked(value);
    }
    function hash4(uint64 a, uint64 b, uint64 c, uint64 d) private pure returns (bytes memory) {
        return bytes.concat(be64(a), be64(b), be64(c), be64(d));
    }
    function word(uint256 value) private pure returns (bytes32) {
        return bytes32(value);
    }
    function segmentCount(uint32 total, uint32 capacity) private pure returns (uint32) {
        return total == 0 ? 0 : uint32((uint256(total) + capacity - 1) / capacity);
    }
    function segmentCountOf(uint32 total, uint32 capacity, uint32 index) private pure returns (uint32) {
        if (total == 0) return 0;
        uint256 first = uint256(index) * capacity;
        uint256 remaining = uint256(total) - first;
        return uint32(remaining < capacity ? remaining : capacity);
    }
    function rewardHeaderBytes(uint32 capacity, uint32 total, uint32 index, bytes32 opening, bytes32 root, bytes memory oldRoot, bytes memory newRoot) private pure returns (bytes memory) {
        uint32 count = segmentCountOf(total, capacity, index);
        return bytes.concat(
            bytes1(uint8(3)), bytes32(uint256(4)), bytes32(uint256(5)), be64(1200), hash4(5, 6, 7, 8),
            be32(capacity), be32(total), be32(segmentCount(total, capacity)), be32(total == 0 ? 0 : index),
            be32(total == 0 ? 0 : uint32(uint256(index) * capacity)), be32(count), oldRoot, newRoot, opening, root
        );
    }
    function canonicalRewardHeader(uint32 capacity, uint32 total, uint32 index) private pure returns (bytes memory) {
        bytes memory same = hash4(1, 2, 3, 4);
        bytes memory next = total == 0 ? same : hash4(8, 7, 6, 5);
        bytes32 opening = total == 0 ? emptyRewardOpening() : bytes32(uint256(6));
        bytes32 root = total == 0 ? emptyClaimRoot(capacity) : bytes32(0);
        return rewardHeaderBytes(capacity, total, index, opening, root, same, next);
    }
    function withdrawalHeaderBytes(uint32 capacity, uint32 total, bytes memory roots) private pure returns (bytes memory) {
        uint32 count = segmentCountOf(total, capacity, 0);
        bytes32 opening = total == 0 ? emptyWithdrawalOpening(roots) : bytes32(uint256(6));
        bytes32 root = total == 0 ? emptyClaimRoot(capacity) : bytes32(0);
        return bytes.concat(
            bytes1(uint8(2)), bytes32(uint256(4)), bytes32(uint256(5)), be64(1200), hash4(5, 6, 7, 8),
            be32(capacity), be32(total), be32(segmentCount(total, capacity)), be32(0), be32(0), be32(count),
            roots, opening, root
        );
    }
    function emptyRewardOpening() private pure returns (bytes32) {
        return keccak256(abi.encodePacked(keccak256("PsyBridge/SourceCheckpointReward/1/Opening"), bytes32(uint256(4)), bytes32(uint256(5)), word(1200), hash4Words(hash4(5, 6, 7, 8)), word(0)));
    }
    function emptyWithdrawalOpening(bytes memory roots) private pure returns (bytes32) {
        bytes memory body = abi.encodePacked(bytes32(uint256(4)), bytes32(uint256(5)), word(1200), hash4Words(hash4(5, 6, 7, 8)), word(roots.length / 32));
        for (uint256 i; i < roots.length; i += 32) {
            bytes memory one = new bytes(32);
            for (uint256 j; j < 32; ++j) one[j] = roots[i + j];
            body = bytes.concat(body, hash4Words(one));
        }
        return keccak256(abi.encodePacked(domain("WithdrawalBatch"), body, word(0)));
    }
    function emptyClaimRoot(uint256 capacity) private pure returns (bytes32) {
        return buildClaimTree(new bytes32[](0), capacity)[0];
    }
    function hash4Words(bytes memory packed) private pure returns (bytes memory) {
        bytes32 root;
        assembly ("memory-safe") { root := mload(add(packed, 32)) }
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }
    function repeatedRoot(uint256 chains) private pure returns (bytes memory roots) {
        bytes memory one = hash4(1, 2, 3, 4);
        roots = new bytes(chains * 32);
        for (uint256 i; i < chains; ++i) {
            for (uint256 j; j < 32; ++j) roots[i * 32 + j] = one[j];
        }
    }
    function leafNode(uint256 count, uint256 ordinal, bytes32 commit) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(domain("Leaf"), MARKER, word(count), word(ordinal), commit));
    }
    function emptyNode(uint256 count, uint256 ordinal) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(domain("Empty"), MARKER, word(count), word(ordinal)));
    }
    function parentNode(uint256 level, bytes32 left, bytes32 right) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(domain("Node"), MARKER, word(level), left, right));
    }
    function buildClaimTree(bytes32[] memory commits, uint256 capacity) private pure returns (bytes32[] memory tree) {
        tree = new bytes32[](2 * capacity - 1);
        uint256 count = commits.length;
        for (uint256 ordinal; ordinal < capacity; ++ordinal) {
            tree[capacity - 1 + ordinal] = ordinal < count ? leafNode(count, ordinal, commits[ordinal]) : emptyNode(count, ordinal);
        }
        for (uint256 level = 1; (capacity >> level) != 0; ++level) {
            uint256 first = (capacity >> level) - 1;
            uint256 end = (capacity >> (level - 1)) - 1;
            for (uint256 index = first; index < end; ++index) tree[index] = parentNode(level, tree[index * 2 + 1], tree[index * 2 + 2]);
        }
    }
    function claimPath(bytes32[] memory tree, uint256 capacity, uint256 ordinal) private pure returns (bytes32[] memory path) {
        uint256 depth;
        for (uint256 width = capacity; width > 1; width >>= 1) ++depth;
        path = new bytes32[](depth);
        uint256 index = capacity - 1 + ordinal;
        for (uint256 level; level < depth; ++level) {
            path[level] = tree[index % 2 == 1 ? index + 1 : index - 1];
            index = (index - 1) / 2;
        }
    }
    function half(bytes32 digest, bool high) private pure returns (uint256) {
        return high ? uint256(uint128(uint256(digest) >> 128)) : uint256(uint128(uint256(digest)));
    }
    function testPackedRewardHeaderRoundTrip() public view {
        bytes memory body = canonicalRewardHeader(1024, 2048, 1);
        assertEq(body.length, 257);
        BridgeOpening.InclusionAggregateHeader memory header = harness.readInclusionAggregateHeader(body);
        assertEq(header.family, 3);
        assertEq(header.configHash, bytes32(uint256(4)));
        assertEq(header.windowId, bytes32(uint256(5)));
        assertEq(header.endCheckpointId, 1200);
        assertEq(header.endCheckpointRoot, bytes32((uint256(5) << 192) | (uint256(6) << 128) | (uint256(7) << 64) | 8));
        assertEq(header.aggregateCapacity, 1024);
        assertEq(header.totalCount, 2048);
        assertEq(header.segmentCount, 2);
        assertEq(header.segmentIndex, 1);
        assertEq(header.firstOrdinal, 1024);
        assertEq(header.count, 1024);
        assertEq(header.withdrawalRoots.length, 0);
        assertEq(header.oldLedgerStateRoot, bytes32((uint256(1) << 192) | (uint256(2) << 128) | (uint256(3) << 64) | 4));
        assertEq(header.newLedgerStateRoot, bytes32((uint256(8) << 192) | (uint256(7) << 128) | (uint256(6) << 64) | 5));
        assertEq(header.openingDigest, bytes32(uint256(6)));
        assertEq(header.claimTreeRoot, bytes32(0));
        assertEq(harness.inclusionHeaderDigest(body), keccak256(abi.encodePacked(domain("AggregateHeader"), body)));
    }
    function testPackedRewardHeaderSegmentBoundaries() public view {
        bytes memory full = canonicalRewardHeader(1024, 1024, 0);
        bytes memory almost = canonicalRewardHeader(1024, 1023, 0);
        bytes memory firstOfTwo = canonicalRewardHeader(1024, 1025, 0);
        bytes memory lastPartial = canonicalRewardHeader(1024, 1025, 1);
        assertEq(harness.readInclusionAggregateHeader(full).count, 1024);
        assertEq(harness.readInclusionAggregateHeader(almost).count, 1023);
        assertEq(harness.readInclusionAggregateHeader(firstOfTwo).count, 1024);
        assertEq(harness.readInclusionAggregateHeader(firstOfTwo).segmentCount, 2);
        assertEq(harness.readInclusionAggregateHeader(lastPartial).count, 1);
        assertEq(harness.readInclusionAggregateHeader(lastPartial).segmentCount, 2);
        assertEq(harness.readInclusionAggregateHeader(canonicalRewardHeader(8192, 8192, 0)).aggregateCapacity, 8192);
        bytes memory zeroDigest = rewardHeaderBytes(1024, 1024, 0, bytes32(0), bytes32(0), hash4(1, 2, 3, 4), hash4(8, 7, 6, 5));
        BridgeOpening.InclusionAggregateHeader memory retained = harness.readInclusionAggregateHeader(zeroDigest);
        assertEq(retained.count, 1024);
        assertEq(retained.openingDigest, bytes32(0));
        assertEq(retained.claimTreeRoot, bytes32(0));
    }
    function testPackedHeadersRejectLengthFamilyAndCanonicalRoot() public {
        bytes memory body = canonicalRewardHeader(1024, 1024, 0);
        bytes memory short = new bytes(body.length - 1);
        for (uint256 i; i < short.length; ++i) short[i] = body[i];
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readInclusionAggregateHeader(short);
        bytes memory long = bytes.concat(body, bytes1(0));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readInclusionAggregateHeader(long);
        bytes memory family = bytes.concat(body);
        family[0] = 0x04;
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readInclusionAggregateHeader(family);
        bytes memory felt = bytes.concat(body);
        for (uint256 i; i < 8; ++i) felt[73 + i] = bytes8(bytes32(uint256(18446744069414584321) << 192))[i];
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readInclusionAggregateHeader(felt);
        bytes memory little = bytes.concat(body);
        little[105] = 0x04;
        little[108] = 0x00;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(little);
    }
    function testWithdrawalHeaderChainVectorLength() public view {
        bytes memory one = withdrawalHeaderBytes(1024, 0, repeatedRoot(1));
        bytes memory full = withdrawalHeaderBytes(1024, 0, repeatedRoot(256));
        assertEq(one.length, 193 + 32);
        assertEq(full.length, 193 + 32 * 256);
        assertEq(harness.readInclusionAggregateHeader(one).withdrawalRoots.length, 1);
        assertEq(harness.readInclusionAggregateHeader(full).withdrawalRoots.length, 256);
        assertEq(harness.readInclusionAggregateHeader(one).oldLedgerStateRoot, bytes32(0));
        assertEq(harness.readInclusionAggregateHeader(full).openingDigest, emptyWithdrawalOpening(repeatedRoot(256)));
        assertEq(harness.readInclusionAggregateHeader(full).claimTreeRoot, emptyClaimRoot(1024));
    }
    function testWithdrawalHeaderRejectsMissingAndNonmultipleRootWidth() public {
        bytes memory one = withdrawalHeaderBytes(1024, 0, repeatedRoot(1));
        bytes memory zero = new bytes(one.length - 32);
        for (uint256 i; i < 193; ++i) zero[i] = one[i];
        for (uint256 i = 225; i < one.length; ++i) zero[i - 32] = one[i];
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(zero);
        bytes memory remainder = bytes.concat(one, bytes1(0));
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(remainder);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(withdrawalHeaderBytes(1024, 0, repeatedRoot(257)));
    }
    function testEmptyRewardRetainsEqualLedgerStateRootsAndZeroDigests() public view {
        bytes memory body = canonicalRewardHeader(1024, 0, 0);
        assertEq(body.length, 257);
        BridgeOpening.InclusionAggregateHeader memory header = harness.readInclusionAggregateHeader(body);
        assertEq(header.count, 0);
        assertEq(header.segmentCount, 0);
        assertEq(header.openingDigest, emptyRewardOpening());
        assertEq(header.claimTreeRoot, emptyClaimRoot(1024));
        assertEq(header.oldLedgerStateRoot, header.newLedgerStateRoot);
    }
    function testEmptyRewardRejectsDistinctLedgerStateRoots() public {
        vm.expectRevert(BridgeOpening.InvalidCursor.selector);
        harness.readInclusionAggregateHeader(rewardHeaderBytes(1024, 0, 0, emptyRewardOpening(), emptyClaimRoot(1024), hash4(1, 2, 3, 4), hash4(8, 7, 6, 5)));
    }
    function testHeaderRejectsUnregisteredCapacityAndSegmentFields() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(canonicalRewardHeader(512, 512, 0));
        bytes memory accepted = canonicalRewardHeader(1024, 1024, 0);
        bytes memory segments = bytes.concat(accepted);
        segments[113] = 0x01;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(segments);
        bytes memory index = bytes.concat(accepted);
        index[117] = 0x01;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(index);
        bytes memory first = bytes.concat(accepted);
        first[121] = 0x01;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(first);
        bytes memory countBytes = bytes.concat(accepted);
        countBytes[125] = 0x01;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readInclusionAggregateHeader(countBytes);
    }
    function testInclusionProofInputsUseIndependentHighHalves() public view {
        bytes memory digest = new bytes(32);
        digest[0] = 0x01;
        digest[31] = 0x02;
        bytes memory body = rewardHeaderBytes(1024, 1024, 0, bytes32(digest), bytes32(uint256(9)), hash4(1, 2, 3, 4), hash4(8, 7, 6, 5));
        uint256[6] memory inputs = harness.inclusionProofInputs(body);
        bytes32 headerDigest = keccak256(abi.encodePacked(domain("AggregateHeader"), body));
        assertEq(inputs[0], uint256(1) << 120);
        assertEq(inputs[1], 2);
        assertNotEq(inputs[0], 0x01000000);
        assertEq(inputs[2], half(bytes32(uint256(9)), true));
        assertEq(inputs[3], half(bytes32(uint256(9)), false));
        assertEq(inputs[4], half(headerDigest, true));
        assertEq(inputs[5], half(headerDigest, false));
        assertEq(inputs[4], half(harness.inclusionHeaderDigest(body), true));
    }
    function testClaimPathAcceptsLocalOrdinalsAndRejectsMutations() public {
        bytes32 left = keccak256("left");
        bytes32 right = keccak256("right");
        bytes32[] memory commits = new bytes32[](2);
        commits[0] = left;
        commits[1] = right;
        bytes32[] memory tree = buildClaimTree(commits, 1024);
        bytes memory body = rewardHeaderBytes(1024, 1026, 1, bytes32(uint256(6)), tree[0], hash4(1, 2, 3, 4), hash4(8, 7, 6, 5));
        BridgeOpening.InclusionAggregateHeader memory header = harness.readInclusionAggregateHeader(body);
        assertEq(header.firstOrdinal, 1024);
        assertEq(header.count, 2);
        bytes32[] memory first = claimPath(tree, 1024, 0);
        bytes32[] memory second = claimPath(tree, 1024, 1);
        assertEq(first.length, 10);
        assertEq(harness.verifyClaimPath(header, 0, left, first), left);
        assertEq(harness.verifyClaimPath(header, 1, right, second), right);
        assertEq(tree[1023], leafNode(2, 0, left));
        assertEq(tree[1025], emptyNode(2, 2));
        vm.expectRevert(BridgeOpening.InvalidProof.selector);
        harness.verifyClaimPath(header, 0, right, first);
        vm.expectRevert(BridgeOpening.InvalidProof.selector);
        harness.verifyClaimPath(header, 1, right, first);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.verifyClaimPath(header, 2, left, first);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.verifyClaimPath(header, 1024, left, first);
        bytes32[] memory short = new bytes32[](first.length - 1);
        for (uint256 i; i < short.length; ++i) short[i] = first[i];
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.verifyClaimPath(header, 0, left, short);
        header.claimTreeRoot = bytes32(uint256(header.claimTreeRoot) ^ 1);
        vm.expectRevert(BridgeOpening.InvalidProof.selector);
        harness.verifyClaimPath(header, 0, left, first);
    }
    function testClaimDepthRejectsZeroAndEighteen() public {
        BridgeOpening.InclusionAggregateHeader memory header;
        header.count = 1;
        bytes32[] memory none = new bytes32[](0);
        header.aggregateCapacity = 0;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.verifyClaimPath(header, 0, bytes32(0), none);
        header.aggregateCapacity = uint32(1 << 18);
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.verifyClaimPath(header, 0, bytes32(uint256(1)), none);
        bytes32[] memory one = new bytes32[](1);
        header.aggregateCapacity = 1;
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.verifyClaimPath(header, 0, bytes32(uint256(1)), one);
    }
    function testDepthZeroAndSeventeenClaimPaths() public {
        bytes32 commit = keccak256("solo");
        bytes32[] memory one = new bytes32[](1);
        one[0] = commit;
        bytes32[] memory tiny = buildClaimTree(one, 1);
        BridgeOpening.InclusionAggregateHeader memory depthZero;
        depthZero.aggregateCapacity = 1;
        depthZero.count = 1;
        depthZero.claimTreeRoot = tiny[0];
        assertEq(harness.verifyClaimPath(depthZero, 0, commit, new bytes32[](0)), commit);
        assertEq(tiny[0], leafNode(1, 0, commit));
        bytes32[] memory wide = new bytes32[](1);
        wide[0] = commit;
        bytes32[] memory deep = buildClaimTree(wide, CLAIM_TREE_MAX_CAPACITY);
        bytes32[] memory path = claimPath(deep, CLAIM_TREE_MAX_CAPACITY, 0);
        BridgeOpening.InclusionAggregateHeader memory depthSeventeen;
        depthSeventeen.aggregateCapacity = uint32(CLAIM_TREE_MAX_CAPACITY);
        depthSeventeen.count = 1;
        depthSeventeen.claimTreeRoot = deep[0];
        assertEq(path.length, 17);
        assertEq(path[0], emptyNode(1, 1));
        assertEq(path[1], parentNode(1, emptyNode(1, 2), emptyNode(1, 3)));
        assertEq(harness.verifyClaimPath(depthSeventeen, 0, commit, path), commit);
        depthSeventeen.claimTreeRoot = bytes32(uint256(deep[0]) ^ 1);
        vm.expectRevert(BridgeOpening.InvalidProof.selector);
        harness.verifyClaimPath(depthSeventeen, 0, commit, path);
    }
    function withdrawalLeafBytes() private pure returns (bytes memory) {
        return abi.encode(
            uint256(255),
            uint256(type(uint32).max),
            address(0x1111111111111111111111111111111111111111),
            address(0),
            uint256(18446744069414584320),
            bytes32(type(uint256).max)
        );
    }
    function sourceCheckpointRewardLeafBytes() private pure returns (bytes memory) {
        return abi.encode(
            bytes32(type(uint256).max),
            uint256(type(uint64).max),
            uint256(type(uint32).max),
            (uint256(0x01020304) << 224) | 1500,
            address(0),
            uint256(1)
        );
    }
    function testSourceCheckpointRewardLeafReadsFullAmountAndLeafCommit() public view {
        bytes memory body = sourceCheckpointRewardLeafBytes();
        assertEq(body.length, 192);
        BridgeOpening.SourceCheckpointRewardLeaf memory leaf = harness.readSourceCheckpointRewardLeaf(body);
        assertEq(leaf.economicDomain, bytes32(type(uint256).max));
        assertEq(leaf.sourceCheckpointId, type(uint64).max);
        assertEq(leaf.userId, type(uint32).max);
        assertEq(leaf.amount, (uint256(0x01020304) << 224) | 1500);
        assertEq(leaf.recipient, address(0));
        assertTrue(leaf.initialized);
        bytes32 commit = harness.sourceCheckpointRewardLeafCommit(body);
        assertEq(commit, keccak256(abi.encodePacked(keccak256("PsyBridge/SourceCheckpointReward/1/Leaf"), body)));
        assertNotEq(commit, keccak256(abi.encodePacked(keccak256("PsyBridge/CumulativeReward/1/Record"), body)));
        assertNotEq(commit, keccak256(abi.encodePacked(domain("Record"), bytes32(uint256(3)), body)));
        assertNotEq(commit, keccak256(abi.encodePacked(domain("RewardBatch"), body)));
    }
    function testSourceCheckpointRewardLeafAllowsZeroAmountAndUninitialized() public view {
        bytes memory body = sourceCheckpointRewardLeafBytes();
        bytes32 previous = harness.sourceCheckpointRewardLeafCommit(body);
        bytes memory zeroAmount = replaceWord(bytes.concat(body), 3, 0);
        BridgeOpening.SourceCheckpointRewardLeaf memory cleared = harness.readSourceCheckpointRewardLeaf(zeroAmount);
        assertEq(cleared.amount, 0);
        assertEq(cleared.sourceCheckpointId, type(uint64).max);
        assertEq(cleared.userId, type(uint32).max);
        assertTrue(cleared.initialized);
        assertEq(cleared.recipient, address(0));
        bytes32 clearedCommit = harness.sourceCheckpointRewardLeafCommit(zeroAmount);
        assertNotEq(clearedCommit, previous);
        assertEq(clearedCommit, keccak256(abi.encodePacked(keccak256("PsyBridge/SourceCheckpointReward/1/Leaf"), zeroAmount)));
        bytes memory dormant = replaceWord(bytes.concat(body), 5, 0);
        BridgeOpening.SourceCheckpointRewardLeaf memory uninitialized = harness.readSourceCheckpointRewardLeaf(dormant);
        assertFalse(uninitialized.initialized);
        assertEq(uninitialized.recipient, address(0));
        assertEq(uninitialized.amount, (uint256(0x01020304) << 224) | 1500);
        assertEq(uninitialized.sourceCheckpointId, type(uint64).max);
        bytes32 dormantCommit = harness.sourceCheckpointRewardLeafCommit(dormant);
        assertNotEq(dormantCommit, previous);
        assertEq(dormantCommit, keccak256(abi.encodePacked(keccak256("PsyBridge/SourceCheckpointReward/1/Leaf"), dormant)));
        bytes memory openDomain = replaceWord(bytes.concat(body), 0, 0);
        assertEq(harness.readSourceCheckpointRewardLeaf(openDomain).economicDomain, bytes32(0));
        bytes memory bound = replaceWord(bytes.concat(body), 4, uint256(uint160(address(0x1111111111111111111111111111111111111111))));
        BridgeOpening.SourceCheckpointRewardLeaf memory paid = harness.readSourceCheckpointRewardLeaf(bound);
        assertEq(paid.recipient, address(0x1111111111111111111111111111111111111111));
        assertTrue(paid.initialized);
        assertEq(paid.amount, (uint256(0x01020304) << 224) | 1500);
        assertNotEq(harness.sourceCheckpointRewardLeafCommit(bound), previous);
        bytes memory source = replaceWord(bytes.concat(body), 1, 1199);
        BridgeOpening.SourceCheckpointRewardLeaf memory sourced = harness.readSourceCheckpointRewardLeaf(source);
        assertEq(sourced.sourceCheckpointId, 1199);
        assertEq(sourced.userId, type(uint32).max);
        assertEq(sourced.amount, (uint256(0x01020304) << 224) | 1500);
        assertNotEq(harness.sourceCheckpointRewardLeafCommit(source), previous);
        bytes memory maxAmount = replaceWord(bytes.concat(body), 3, type(uint256).max);
        assertEq(harness.readSourceCheckpointRewardLeaf(maxAmount).amount, type(uint256).max);
        assertEq(harness.readSourceCheckpointRewardLeaf(maxAmount).sourceCheckpointId, type(uint64).max);
        assertEq(harness.sourceCheckpointRewardLeafCommit(maxAmount), keccak256(abi.encodePacked(keccak256("PsyBridge/SourceCheckpointReward/1/Leaf"), maxAmount)));
        assertNotEq(harness.sourceCheckpointRewardLeafCommit(maxAmount), previous);
    }
    function testSourceCheckpointRewardLeafRejectsLengthPaddingBooleanAndRecipient() public {
        bytes memory body = sourceCheckpointRewardLeafBytes();
        bytes memory legacy = new bytes(160);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readSourceCheckpointRewardLeaf(legacy);
        bytes memory short = new bytes(191);
        for (uint256 i; i < short.length; ++i) short[i] = body[i];
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readSourceCheckpointRewardLeaf(short);
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.sourceCheckpointRewardLeafCommit(bytes.concat(body, bytes1(0)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readSourceCheckpointRewardLeaf(replaceWord(bytes.concat(body), 1, uint256(1) << 64));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readSourceCheckpointRewardLeaf(replaceWord(bytes.concat(body), 2, uint256(1) << 32));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readSourceCheckpointRewardLeaf(replaceWord(bytes.concat(body), 4, uint256(1) << 160));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readSourceCheckpointRewardLeaf(replaceWord(bytes.concat(body), 5, 2));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.sourceCheckpointRewardLeafCommit(replaceWord(bytes.concat(body), 5, uint256(1) << 64));
        bytes memory recipient = replaceWord(bytes.concat(body), 4, uint256(uint160(address(15))));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.sourceCheckpointRewardLeafCommit(replaceWord(recipient, 5, 0));
    }
    function testParentDigestExcludesDirectWindowKeepsEncodedWindow() public view {
        bytes memory deposits = depositOpening();
        bytes memory header = new bytes(224);
        for (uint256 i; i < header.length; ++i) header[i] = deposits[i];
        bytes32 configHash = keccak256(bytes.concat(domain("Config"), configBytes()));
        bytes32 windowId;
        assembly ("memory-safe") { windowId := mload(add(header, 64)) }
        bytes32 endRoot = bytes32((uint256(1) << 192) | (uint256(2) << 128) | (uint256(3) << 64) | 4);
        bytes32 startRoot = endRoot;
        bytes32 depositRoot = bytes32((uint256(5) << 192) | (uint256(6) << 128) | (uint256(7) << 64) | 8);
        bytes32 withdrawalRoot = bytes32(0);
        bytes32 ledgerRoot = bytes32(0);
        bytes32 economic = bytes32(uint256(0xbb));
        bytes memory encoded = bytes.concat(
            header, _vectorU32x8(bytes32(0)), _vectorU32x8(bytes32(0)),
            abi.encode(uint256(1)), _vectorRoot(startRoot), abi.encode(uint256(1)),
            abi.encode(uint256(1)), _vectorRoot(depositRoot), abi.encode(uint256(0)), _vectorRoot(withdrawalRoot),
            abi.encode(uint256(0)), _vectorRoot(ledgerRoot), _vectorRoot(ledgerRoot), abi.encode(economic, uint256(0))
        );
        bytes32 depositDigest = bytes32(uint256(0xcc));
        BridgeOpening.WindowFinalizationOpening memory opening = harness.readWindowFinalizationOpening(configBytes(), encoded, depositDigest);
        assertEq(opening.windowId, windowId);
        assertEq(opening.configHash, configHash);
        bytes32 batchRoot = keccak256(abi.encodePacked(keccak256("PsyBridge/TwoArtifact/2/Empty"), bytes32(uint256(0)), bytes32(uint256(0))));
        bytes memory excluded = abi.encodePacked(keccak256("PsyBridge/TwoArtifact/2/B"), configHash, bytes32(uint256(0)), _vectorRoot(endRoot), depositDigest);
        bytes memory included = abi.encodePacked(keccak256("PsyBridge/TwoArtifact/2/B"), configHash, windowId, bytes32(uint256(0)), _vectorRoot(endRoot), depositDigest);
        assertEq(included.length, excluded.length + 32);
        bytes32 expected = keccak256(bytes.concat(
            excluded, _vectorU32x8(bytes32(0)), _vectorU32x8(bytes32(0)), abi.encode(uint256(1)),
            _vectorRoot(startRoot), abi.encode(uint256(1)),
            _vectorRoot(depositRoot), abi.encode(uint256(0)), _vectorRoot(withdrawalRoot),
            abi.encode(uint256(0), uint256(0)), _vectorRoot(ledgerRoot), _vectorRoot(ledgerRoot),
            abi.encode(economic, uint256(0), batchRoot)
        ));
        bytes32 stale = keccak256(bytes.concat(
            included, _vectorU32x8(bytes32(0)), _vectorU32x8(bytes32(0)), abi.encode(uint256(1)),
            _vectorRoot(startRoot), abi.encode(uint256(1)),
            _vectorRoot(depositRoot), abi.encode(uint256(0)), _vectorRoot(withdrawalRoot),
            abi.encode(uint256(0), uint256(0)), _vectorRoot(ledgerRoot), _vectorRoot(ledgerRoot),
            abi.encode(economic, uint256(0), batchRoot)
        ));
        assertEq(opening.openingDigest, expected);
        assertNotEq(expected, stale);
    }
    function _vectorRoot(bytes32 root) private pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }
    function _vectorU32x8(bytes32 packed) private pure returns (bytes memory) {
        uint256 value = uint256(packed);
        uint256 mask = type(uint32).max;
        return abi.encode((value >> 224) & mask, (value >> 192) & mask, (value >> 160) & mask, (value >> 128) & mask, (value >> 96) & mask, (value >> 64) & mask, (value >> 32) & mask, value & mask);
    }

}
