// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WETH9} from "./WETH9.sol";

/// @notice Backward-compatible alias for tests that still import MockWETH.
contract MockWETH is WETH9 {}
