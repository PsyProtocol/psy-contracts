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
            uint256(0x000000000000000000000000000000007b931f4f448a3e3fcae8408f56cec0d5),
            uint256(0x00000000000000000000000000000000a60ab4615d7a0d9770b60f3d7bc998d5)
        ];
    }

    function _uncompressedProofFromOutProofJson() internal pure returns (uint256[8] memory proof) {
        proof = [
            uint256(0x1cbfcb5b4767ea73eebd161f03d037b08c8ae5ad41c2b2be97169c1c924bd2e4),
            uint256(0x03775867cffa7a5d1096a401fbc7078feeaca19e9ee0315654c3b57d0e31c12a),
            uint256(0x128b930ca7bfc5fd2aa52b621eb47cf356cab4d085d1e18001511b0a8912b36b),
            uint256(0x17dae318d55e41714c9f2f5b8f6c24ec887e3ecb9be8032685329bd3494e1d59),
            uint256(0x04b4cfd9bd0e46841df482202d35a980f720d2055b7bea5f9bd5a623b598a0e1),
            uint256(0x2f41a19d630b4004afc3a60102a8743f396ab1a3c33ec40fccf6c7a663610afc),
            uint256(0x135fd400e1f8c4217196c4db47a4a28485f0f3cc539bf7863b2b07709a666781),
            uint256(0x120340f3d5d51c4814dd0ac0fce3305d8636bb404983688861fbb53b7bc0aad8)
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
