// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockGnarkVerifier {
    bool public shouldVerify = true;

    function setShouldVerify(bool v) external {
        shouldVerify = v;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata) external view {
        require(shouldVerify, "invalid proof");
    }
}
