// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Verifier} from "../../src/GnarkGroth16Verifier.sol";

contract GnarkGroth16VerifierForkTest is Test {
    Verifier internal verifier;

    function setUp() public {
        verifier = new Verifier();
    }

    function _publicInputs() internal pure returns (uint256[2] memory input) {
        input = [
            uint256(0x000000000000000000000000000000006030bafd0fe5bb433f7ab7322de25d45),
            uint256(0x000000000000000000000000000000001a6b7d2ac2240435041e039b8cf34adf)
        ];
    }

    function _uncompressedProofFromOutProofJson() internal pure returns (uint256[8] memory proof) {
        proof = [
            uint256(0x152c2d58a91ec8b9692d1938abfbea034c96fbe17c05404d7da348043a8326a5),
            uint256(0x302eed4c01e36e0e496348b7270b442981cc966b6f72f08d87655c24c6bd46d3),
            uint256(0x1721203cfcaea29d6fdfdacba2abb26a13bf9b36ddc7874dac895d7e2a1f54d6),
            uint256(0x00611933bc6782e1d782da1f934093995faffbd6634056effab56f45a58d8ba3),
            uint256(0x257f38bbcc736e216cc387e3d63ce1a9bc6dcffcb125a0074e9226cf36af32dc),
            uint256(0x23f526458585cbc0eadc1b952331e0042b207e5b9aedcfc448e84d7438c1d0db),
            uint256(0x2d6eb29ae13b7415f0e016470148d9cd7344f9a4987b3b9387390c5be7031728),
            uint256(0x108f77ac6b890a9a03deff7a8b49a903310d55cb22201acbe841dc9e69c2e522)
        ];
    }

    // Fork test (run with --fork-url): checks current out_proof.json against verifier.
    function testMainnetForkVerifyUncompressedProofFromOutProofJson() public {
        uint256[2] memory input = _publicInputs();
        uint256[8] memory proof = _uncompressedProofFromOutProofJson();
        verifier.verifyProof(proof, input);
    }

    function testMainnetForkVerifyUncompressedProofTamperedInputFails() public {
        uint256[2] memory input = _publicInputs();
        uint256[8] memory proof = _uncompressedProofFromOutProofJson();
        input[1] ^= 1;
        vm.expectRevert();
        verifier.verifyProof(proof, input);
    }
}
