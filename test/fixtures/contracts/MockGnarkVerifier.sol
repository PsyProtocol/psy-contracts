// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockGnarkVerifier {
    bool public shouldVerify = true;

    // Orchestration-only metadata; this mock does not establish cryptographic acceptance.
    mapping(uint8 => mapping(uint32 => bytes32)) private policyHashes;

    function withdrawalTokenPolicyHash(uint8 chainIndex, uint32 contractId) external view returns (bytes32) {
        return policyHashes[chainIndex][contractId];
    }

    function setWithdrawalTokenPolicy(
        uint8 chainIndex,
        uint32 contractId,
        address token,
        bytes32 fullLeafHash,
        uint32 physicalMapBase,
        uint32 capacity,
        uint8 height
    ) external {
        policyHashes[chainIndex][contractId] =
            keccak256(abi.encode(chainIndex, contractId, token, fullLeafHash, physicalMapBase, capacity, height));
    }

    function setShouldVerify(bool v) external {
        shouldVerify = v;
    }

    function setWithdrawalTokenPolicyHash(uint8 chainIndex, uint32 contractId, bytes32 hash) external {
        policyHashes[chainIndex][contractId] = hash;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata) external view {
        require(shouldVerify, "invalid proof");
    }
}
