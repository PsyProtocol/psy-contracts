// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract TestTransparentUpgradeableProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address initialOwner, bytes memory initData)
        TransparentUpgradeableProxy(implementation, initialOwner, initData)
    {}
}
