// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Verifier} from "../../src/GnarkGroth16Verifier.sol";

contract GnarkGroth16VerifierTest is Test {
    Verifier internal verifier;

    function setUp() public {
        verifier = new Verifier();
    }

    function _publicInputs() internal pure returns (uint256[2] memory input) {
        input = [
            uint256(0x00000000000000000000000000000000692127e3a69c4a65c414864a64d7c993),
            uint256(0x00000000000000000000000000000000d4d7d0aa1ae15aa422e62bf1868fb9d3)
        ];
    }

    function _uncompressedProofFromOutProofJson() internal pure returns (uint256[8] memory proof) {
        proof = [
            uint256(0x3122be64caeb9d237a379f2536405b3a8a82d381c1dfe393a5988feefb6a6d),
            uint256(0x2bb9ce3c716fa3cf8dd6bfdae58a18c3ee259f06b39eb20eadc04114378a52d1),
            uint256(0x1d1471e711c884cbf5a56c9ce1f6479fd49c0c90d79c47630ec068e5402ef72c),
            uint256(0x1d222c08d3c8770afd8f8f51b4231d5bbc79d9b0f00985c1433eea2f9c06587),
            uint256(0x29c43359862ed08296d81052ed866e23d8125502b791bc59166d1e6aafd705c5),
            uint256(0x108c7e71e79cbb4c5a6e088b9d882841638c9284c9cd9ffe7caf8b3c637a11d9),
            uint256(0x27871f7b214707109badd510aac0de18e76cd8b1a19e4d9e4761e35a2a0d18e9),
            uint256(0x1be73309e8803430c1b204e3903c39d457f05379cca15fe934776f3c9c5d6106)
        ];
    }

    function testVerifyOutProofJsonUncompressed() public {
        uint256[2] memory input = _publicInputs();
        uint256[8] memory proof = _uncompressedProofFromOutProofJson();
        verifier.verifyProof(proof, input);
    }

    function testVerifyOutProofJsonTamperedInputUncompressed() public {
        uint256[8] memory proof = _uncompressedProofFromOutProofJson();
        uint256[2] memory input = _publicInputs();
        input[1] ^= 1;
        vm.expectRevert();
        verifier.verifyProof(proof, input);
    }
}
