// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockGnarkVerifier {
    bool public shouldVerify = true;

    // Orchestration-only metadata; this mock does not establish cryptographic acceptance.
    function endpointChainListHash() external pure returns (bytes32) {
        return keccak256(abi.encodePacked("PsyBridge/FinalizeChainList/1", uint16(1), uint8(0)));
    }

    function setShouldVerify(bool v) external {
        shouldVerify = v;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata) external view {
        require(shouldVerify, "invalid proof");
    }
}
