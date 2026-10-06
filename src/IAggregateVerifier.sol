// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAggregateVerifier {
    function verifyProof(uint256[8] calldata proof, uint256[2] calldata input) external view;
}

interface IFinalizeVerifier is IAggregateVerifier {
    function endpointChainListHash() external pure returns (bytes32);
}
