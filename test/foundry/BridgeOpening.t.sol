// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BridgeOpening} from "../../src/BridgeOpening.sol";

contract BridgeOpeningHarness {
    function readA(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readA(opening, BridgeOpening.readConfig(config)).statementA;
    }
    function readB(bytes calldata config, bytes calldata opening) external pure returns (bytes32) {
        return BridgeOpening.readB(opening, BridgeOpening.readConfig(config)).statementB;
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
    function openingA() private pure returns (bytes memory) {
        bytes32 configHash = keccak256(bytes.concat(domain("Config"), configBytes()));
        bytes memory end = abi.encode(uint256(0), uint256(1), uint256(2), uint256(3), uint256(4));
        bytes memory starts = abi.encode(uint256(1), uint256(1), uint256(0), uint256(1), uint256(2), uint256(3), uint256(4));
        bytes memory deposits = abi.encode(uint256(1), uint256(1), uint256(5), uint256(6), uint256(7), uint256(8), uint256(5), uint256(6), uint256(7), uint256(8), uint256(0), uint256(0));
        bytes32 windowId = keccak256(bytes.concat(domain("Window"), configHash, end, starts, deposits));
        return bytes.concat(abi.encode(configHash, windowId), end, starts, deposits, abi.encode(uint256(0)));
    }
    function openingB(bytes memory withdrawals, bytes memory rewards) private pure returns (bytes memory) {
        bytes memory ends = abi.encode(uint256(1), uint256(1), uint256(5), uint256(6), uint256(7), uint256(8), uint256(0), uint256(9), uint256(10), uint256(11), uint256(12));
        return bytes.concat(openingA(), ends, withdrawals, rewards);
    }
    function replaceWord(bytes memory body, uint256 index, uint256 value) private pure returns (bytes memory) {
        assembly ("memory-safe") { mstore(add(add(body, 32), mul(index, 32)), value) }
        return body;
    }
    function testEmptyFamiliesUseDistinctPositionBoundDomains() public view {
        bytes memory a = openingA();
        bytes memory projection = new bytes(a.length - 32);
        for (uint256 i; i < projection.length; ++i) projection[i] = a[i];
        bytes32 emptyDeposit = keccak256(abi.encode(domain("Empty"), uint256(1), uint256(0)));
        bytes32 expectedA = keccak256(bytes.concat(domain("A"), projection, abi.encode(uint256(0), uint256(0), emptyDeposit)));
        assertEq(harness.readA(configBytes(), a), expectedA);
        bytes memory b = openingB(abi.encode(uint256(0)), abi.encode(uint256(0)));
        bytes memory ends = new bytes(11 * 32);
        for (uint256 i; i < ends.length; ++i) ends[i] = b[a.length + i];
        bytes32 expectedB = keccak256(bytes.concat(domain("B"), expectedA, ends,
            abi.encode(uint256(0), uint256(0), keccak256(abi.encode(domain("Empty"), uint256(2), uint256(0)))),
            abi.encode(uint256(0), uint256(0), keccak256(abi.encode(domain("Empty"), uint256(3), uint256(0))))));
        assertEq(harness.readB(configBytes(), b), expectedB);
    }
    function testRejectsTrailingOpeningWord() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readA(configBytes(), bytes.concat(openingA(), abi.encode(uint256(0))));
    }
    function testRejectsTruncatedFullOpening() public {
        bytes memory a = openingA();
        assembly ("memory-safe") { mstore(a, sub(mload(a), 32)) }
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readA(configBytes(), a);
    }
    function testRejectsNoncanonicalFelt() public {
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readA(configBytes(), replaceWord(openingA(), 3, 18446744069414584321));
    }
    function testRejectsDifferentBridgeIdentity() public {
        vm.expectRevert(BridgeOpening.InvalidConfig.selector);
        harness.readA(replaceWord(configBytes(), 2, 524289), openingA());
    }
    function testRejectsOmittedConfiguredChain() public {
        vm.expectRevert(BridgeOpening.InvalidCount.selector);
        harness.readA(configBytes(), replaceWord(openingA(), 7, 0));
    }
    function testRejectsAddressHighBits() public {
        bytes memory withdrawal = abi.encode(uint256(1), uint256(1), uint256(7), (uint256(1) << 160) | 15, uint256(0), uint256(1), bytes32(uint256(4)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(withdrawal, abi.encode(uint256(0))));
    }
    function testRejectsDuplicateNonceWithDifferentRecipient() public {
        bytes memory withdrawals = bytes.concat(abi.encode(uint256(2)),
            abi.encode(uint256(1), uint256(7), address(15), address(0), uint256(1), bytes32(uint256(4))),
            abi.encode(uint256(1), uint256(8), address(16), address(0), uint256(1), bytes32(uint256(4))));
        vm.expectRevert(BridgeOpening.InvalidOrdering.selector);
        harness.readB(configBytes(), openingB(withdrawals, abi.encode(uint256(0))));
    }
    function testRejectsAmountAtFieldModulus() public {
        bytes memory withdrawal = abi.encode(uint256(1), uint256(1), uint256(7), address(15), address(0), uint256(18446744069414584321), bytes32(uint256(4)));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(withdrawal, abi.encode(uint256(0))));
    }
    function testRejectsRewardOutsideGutaSubtree() public {
        bytes memory rewards = abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(1), uint256(4), address(15));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(abi.encode(uint256(0)), rewards));
    }
    function testRejectsRewardNullifierRelabeling() public {
        bytes memory rewards = abi.encode(uint256(1), uint256(0), uint256(7), uint256(2), uint256(0), uint256(4), address(15));
        vm.expectRevert(BridgeOpening.InvalidEncoding.selector);
        harness.readB(configBytes(), openingB(abi.encode(uint256(0)), rewards));
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
        bytes32 opening = total == 0 ? bytes32(0) : bytes32(uint256(6));
        return rewardHeaderBytes(capacity, total, index, opening, bytes32(0), same, next);
    }
    function withdrawalHeaderBytes(uint32 capacity, uint32 total, bytes memory roots) private pure returns (bytes memory) {
        uint32 count = segmentCountOf(total, capacity, 0);
        bytes32 opening = total == 0 ? bytes32(0) : bytes32(uint256(6));
        return bytes.concat(
            bytes1(uint8(2)), bytes32(uint256(4)), bytes32(uint256(5)), be64(1200), hash4(5, 6, 7, 8),
            be32(capacity), be32(total), be32(segmentCount(total, capacity)), be32(0), be32(0), be32(count),
            roots, opening, bytes32(0)
        );
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
        assertEq(header.oldNullifierRoot, bytes32((uint256(1) << 192) | (uint256(2) << 128) | (uint256(3) << 64) | 4));
        assertEq(header.newNullifierRoot, bytes32((uint256(8) << 192) | (uint256(7) << 128) | (uint256(6) << 64) | 5));
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
        assertEq(harness.readInclusionAggregateHeader(one).oldNullifierRoot, bytes32(0));
        assertEq(harness.readInclusionAggregateHeader(full).openingDigest, bytes32(0));
        assertEq(harness.readInclusionAggregateHeader(full).claimTreeRoot, bytes32(0));
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
    function testEmptyRewardRetainsEqualNullifierRootsAndZeroDigests() public view {
        bytes memory body = canonicalRewardHeader(1024, 0, 0);
        assertEq(body.length, 257);
        BridgeOpening.InclusionAggregateHeader memory header = harness.readInclusionAggregateHeader(body);
        assertEq(header.count, 0);
        assertEq(header.segmentCount, 0);
        assertEq(header.openingDigest, bytes32(0));
        assertEq(header.claimTreeRoot, bytes32(0));
        assertEq(header.oldNullifierRoot, header.newNullifierRoot);
        assertEq(uint8(body[body.length - 1]), 0);
        assertEq(uint8(body[body.length - 64]), 0);
    }
    function testEmptyRewardRejectsDistinctNullifierRoots() public {
        vm.expectRevert(BridgeOpening.InvalidCursor.selector);
        harness.readInclusionAggregateHeader(rewardHeaderBytes(1024, 0, 0, bytes32(0), bytes32(0), hash4(1, 2, 3, 4), hash4(8, 7, 6, 5)));
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
}
