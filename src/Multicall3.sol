// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal Multicall3 (aggregate3) for batching external calls.
contract Multicall3 {
    struct Call3 {
        address target;
        bool allowFailure;
        bytes callData;
    }

    struct Result {
        bool success;
        bytes returnData;
    }

    error CallFailed(uint256 index, bytes returnData);

    function aggregate3(Call3[] calldata calls) external payable returns (Result[] memory returnData) {
        uint256 length = calls.length;
        returnData = new Result[](length);

        for (uint256 i = 0; i < length; ++i) {
            Call3 calldata calli = calls[i];
            (bool success, bytes memory ret) = calli.target.call(calli.callData);
            if (!calli.allowFailure && !success) {
                revert CallFailed(i, ret);
            }
            returnData[i] = Result(success, ret);
        }
    }
}
