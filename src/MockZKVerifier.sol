// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockZKVerifier {
    bool public shouldVerify = true;

    function setShouldVerify(bool v) external {
        shouldVerify = v;
    }

    function verify(bytes calldata, uint256[] calldata) external view returns (bool) {
        return shouldVerify;
    }

    function verifyProof(uint256[8] calldata, uint256[] calldata) external view returns (bool) {
        return shouldVerify;
    }

    function verifyProof(uint256[8] calldata, uint256[2] calldata) external view {
        require(shouldVerify, "invalid proof");
    }
}
