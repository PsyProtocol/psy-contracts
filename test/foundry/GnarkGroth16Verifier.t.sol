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
            uint256(0x00000000000000000000000000000000e37253d0a1db12bf2eba1363b6cfac34),
            uint256(0x00000000000000000000000000000000ee99ae2a8335afcf06894e2d35ef92b5)
        ];
    }

    function _uncompressedProofFromOutProofJson() internal pure returns (uint256[8] memory proof) {
        proof = [
            uint256(0x1a228c54d91c86b33583c254c079d45ba295c9c461c825cc28adca8b761f4f44),
            uint256(0x264bb0e812f6ef5d5fd830e26d0f336ed727342d046e0f819439974e69939f3e),
            uint256(0x07cb9d503574217cc250db01799de7f15ce17e8f6ea80eabbfb44f624f8aa7e5),
            uint256(0x1c149520ccdfae226456c7264f46f4627bdb0011b783d3b2fae8bddb7921c276),
            uint256(0x24e6e856459493ca74372e9f86c55913b4f039dc0fc83818141c02a6f4a8286c),
            uint256(0x0549a66fc110b806e972cb012d81ca75eb9b15a24e1695565fd33692a2ec4c02),
            uint256(0x078337fd7ec2b4fb4a7877f16661d7aad92721d7bd6865ec5c8ecdff1243e96a),
            uint256(0x263e9724f26ce571c12eaea7d9043f6118aecb0f12c74ae92953745521544b18)
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
