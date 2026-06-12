// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract KeccakPublicInputsTest is Test {
    function testKeccakPublicInputs() public {
        uint64[25] memory pub_inputs = [
            uint64(8566162305328835118),
            17073938949436608506,
            5324838666364084510,
            185291676663134125,
            2085891226,
            831684258,
            1983696930,
            692453930,
            767848033,
            1322808135,
            3888295851,
            1450101829,
            658399741,
            2344063542,
            4055224794,
            3632866188,
            3253415608,
            422030250,
            2214965705,
            446410139,
            15640124050670338001,
            9030451105071128169,
            1889561579968406848,
            9282790487812902350,
            524288
        ];

        bytes memory packed = new bytes(25 * 8 - 16 * 4);
        uint256 offset = 0;
        for (uint256 i = 0; i < 25; i++) {
            uint64 v = pub_inputs[i];
            if (i >= 4 && i < 20) {
                uint32 v32 = uint32(v);
                for (uint256 j = 0; j < 4; j++) {
                    packed[offset + j] = bytes1(uint8(v32 >> (24 - j * 8)));
                }
                offset += 4;
            } else {
                for (uint256 j = 0; j < 8; j++) {
                    packed[offset + j] = bytes1(uint8(v >> (56 - j * 8)));
                }
                offset += 8;
            }
        }

        bytes32 h = keccak256(packed);
        emit log_named_bytes32("keccak256", h);
        assertEq(h, 0xbb024b73abddb6fae71bcdc8f4d9b38b4309756f72918b7d6641fed94aee6d5d);
    }
}
