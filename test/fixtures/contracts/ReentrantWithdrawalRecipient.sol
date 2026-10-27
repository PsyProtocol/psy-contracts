// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract ReentrantWithdrawalRecipient {
    address public bridge;
    bytes32 public nonce;
    bytes public batchCallData;
    bool public pendingBlocked;
    bool public governanceBlocked;
    bool public batchBlocked;

    constructor(address target, bytes32 pendingNonce) {
        bridge = target;
        nonce = pendingNonce;
    }

    function setBatchCallData(bytes calldata data) external {
        batchCallData = data;
    }

    receive() external payable {
        bytes4 expected = bytes4(keccak256("WithdrawalSettlementReentered()"));
        (bool ok, bytes memory reason) = bridge.call(abi.encodeWithSignature("claimPendingWithdrawal(bytes32)", nonce));
        pendingBlocked = !ok && bytes4(reason) == expected;
        (ok, reason) = bridge.call(abi.encodeWithSignature("forceClaimWithdrawal(bytes32)", nonce));
        governanceBlocked = !ok && bytes4(reason) == expected;
        (ok, reason) = bridge.call(batchCallData);
        batchBlocked = !ok && bytes4(reason) == expected;
    }
}
