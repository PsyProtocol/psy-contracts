// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITokenGateway {
    function deposit(address depositor, address token, uint256 amount, bytes32 shieldAddress, bytes32 noteSecretHash)
        external
        payable
        returns (uint32 index, bytes32 newRoot);
}
