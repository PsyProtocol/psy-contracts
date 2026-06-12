// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract IncrementalMerkleTree is Initializable {
    uint8 public treeDepth;
    uint16 public rootHistorySize;

    uint32 public leafCount;
    bytes32[] internal _frontier;
    bytes32[] internal _zeroHashes;
    bytes32[] internal _roots;
    uint16 public currentRootIndex;

    error TreeFull();
    error InvalidDepth();
    error InvalidRootHistorySize();

    function __IncrementalMerkleTree_init(uint8 depth_, uint16 rootHistorySize_) internal onlyInitializing {
        if (depth_ == 0 || depth_ > 64) revert InvalidDepth();
        if (rootHistorySize_ == 0) revert InvalidRootHistorySize();

        treeDepth = depth_;
        rootHistorySize = rootHistorySize_;

        _frontier = new bytes32[](depth_);
        _zeroHashes = new bytes32[](depth_ + 1);
        _roots = new bytes32[](rootHistorySize_);

        _zeroHashes[0] = bytes32(0);
        for (uint8 i = 0; i < depth_; ++i) {
            _zeroHashes[i + 1] = keccak256(abi.encodePacked(_zeroHashes[i], _zeroHashes[i]));
            _frontier[i] = _zeroHashes[i];
        }

        _roots[0] = _zeroHashes[depth_];
    }

    function _disableIncrementalMerkleTreeInitializers() internal {
        _disableInitializers();
    }

    function _hashNode(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    function appendLeaf(bytes32 leaf) internal returns (uint32 index, bytes32 newRoot) {
        bytes32[32] memory unusedSiblings;
        (index, newRoot, unusedSiblings) = appendLeafWithProof(leaf);
    }

    function appendLeafWithProof(bytes32 leaf) internal returns (uint32 index, bytes32 newRoot, bytes32[32] memory siblings) {
        index = leafCount;
        if (uint256(index) >= (uint256(1) << treeDepth)) revert TreeFull();

        bytes32 current = leaf;
        uint32 idx = index;

        for (uint8 level = 0; level < treeDepth; ++level) {
            if ((idx & 1) == 0) {
                siblings[level] = _zeroHashes[level];
                _frontier[level] = current;
                current = _hashNode(current, _zeroHashes[level]);
            } else {
                siblings[level] = _frontier[level];
                current = _hashNode(_frontier[level], current);
            }
            idx >>= 1;
        }

        leafCount = index + 1;
        currentRootIndex = uint16((currentRootIndex + 1) % rootHistorySize);
        _roots[currentRootIndex] = current;
        return (index, current, siblings);
    }

    function getLatestRoot() public view returns (bytes32) {
        return _roots[currentRootIndex];
    }

    function getRootByRingIndex(uint16 ringIndex) public view returns (bytes32) {
        require(ringIndex < rootHistorySize, "ringIndex out of range");
        return _roots[ringIndex];
    }

    function isKnownRoot(bytes32 root) public view returns (bool) {
        if (root == bytes32(0)) return false;
        for (uint256 i = 0; i < rootHistorySize; ++i) {
            if (_roots[i] == root) return true;
        }
        return false;
    }
}
