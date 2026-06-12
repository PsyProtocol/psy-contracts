// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IncrementalMerkleTreeHarness} from "../../src/IncrementalMerkleTreeHarness.sol";

contract IncrementalMerkleTreeTest is Test {
    function testAppendAndKnownRoot() public {
        IncrementalMerkleTreeHarness tree = new IncrementalMerkleTreeHarness();
        tree.initializeHarness(4, 8);

        bytes32 initialRoot = tree.getLatestRoot();
        (uint32 idx0, bytes32 root0) = tree.append(keccak256("leaf-0"));
        (uint32 idx1, bytes32 root1) = tree.append(keccak256("leaf-1"));

        assertEq(idx0, 0);
        assertEq(idx1, 1);
        assertTrue(initialRoot != root0);
        assertTrue(root0 != root1);
        assertTrue(tree.isKnownRoot(root1));
    }

    function testRootHistoryRingBuffer() public {
        IncrementalMerkleTreeHarness tree = new IncrementalMerkleTreeHarness();
        tree.initializeHarness(4, 2);

        (, bytes32 r0) = tree.append(keccak256("A"));
        (, bytes32 r1) = tree.append(keccak256("B"));
        (, bytes32 r2) = tree.append(keccak256("C"));

        assertTrue(tree.isKnownRoot(r1));
        assertTrue(tree.isKnownRoot(r2));
        assertFalse(tree.isKnownRoot(r0));
    }
}
