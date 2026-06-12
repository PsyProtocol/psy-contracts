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
            uint256(0x00000000000000000000000000000000bb024b73abddb6fae71bcdc8f4d9b38b),
            uint256(0x000000000000000000000000000000004309756f72918b7d6641fed94aee6d5d)
        ];
    }

    function _uncompressedProofFromOutProofJson() internal pure returns (uint256[8] memory proof) {
        proof = [
            uint256(0x0ef0041be07aa777a75909317fe7fc49f721d5af942db4b9517ff4c8addc466c),
            uint256(0x0b1130fc8c030587d214deb4f1f21b8e87ead909e53572bd4962737ff4eeb972),
            uint256(0x22c86cea55cd8cf19c7e92c1be510ab1195f9224fdcef7c353ab2f97805a616b),
            uint256(0x04fbd4184979bf93ec5b7331f5d051d9da5eb7a3aa71fe6414c02214477ec697),
            uint256(0x0d01aca5a92c62c881d027078fd31ef2b1d75bb46b648204b4b98bc826cd6557),
            uint256(0x25e8e2b7cedd74515243f1f59e7c709ff3b129cae7d4e170c2f96f2c16aee513),
            uint256(0x14d8b9c25dca9ee452ea72c0abe5ff4680393743c9ef2b298013449b13ab19e8),
            uint256(0x19877376db1ca3170901bf4baf3ac52ea1ad7069217fa54901ad5798c5a94d5c)
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
