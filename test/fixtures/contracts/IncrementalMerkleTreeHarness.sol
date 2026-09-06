// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../src/IncrementalMerkleTree.sol";

contract IncrementalMerkleTreeHarness is IncrementalMerkleTree {
    function initializeHarness(uint8 depth_, uint16 rootHistorySize_) external initializer {
        __IncrementalMerkleTree_init(depth_, rootHistorySize_);
    }

    function append(bytes32 leaf) external returns (uint32 index, bytes32 newRoot) {
        return appendLeaf(leaf);
    }
}
