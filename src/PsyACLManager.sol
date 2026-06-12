// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract PsyACLManager is Initializable, OwnableUpgradeable, AccessControlUpgradeable {
    uint256 public constant VERSION = 1;

    bytes32 public constant BRIDGE_ADMIN_ROLE = keccak256("BRIDGE_ADMIN");
    bytes32 public constant ROUTER_ADMIN_ROLE = keccak256("ROUTER_ADMIN");
    bytes32 public constant STATE_MANAGER_ADMIN_ROLE = keccak256("STATE_MANAGER_ADMIN");
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER");

    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address bridgeAdmin_,
        address routerAdmin_,
        address stateManagerAdmin_,
        address proposer_
    ) external initializer {
        __Ownable_init(owner_);
        __AccessControl_init();

        if (owner_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(BRIDGE_ADMIN_ROLE, bridgeAdmin_);
        _grantRole(ROUTER_ADMIN_ROLE, routerAdmin_);
        _grantRole(STATE_MANAGER_ADMIN_ROLE, stateManagerAdmin_);
        _grantRole(PROPOSER_ROLE, proposer_);
    }

    function getRevision() external pure returns (uint256) {
        return VERSION;
    }

    function isBridgeAdmin(address account) external view returns (bool) {
        return hasRole(BRIDGE_ADMIN_ROLE, account);
    }

    function isRouterAdmin(address account) external view returns (bool) {
        return hasRole(ROUTER_ADMIN_ROLE, account);
    }

    function isStateManagerAdmin(address account) external view returns (bool) {
        return hasRole(STATE_MANAGER_ADMIN_ROLE, account);
    }

    function isProposer(address account) external view returns (bool) {
        return hasRole(PROPOSER_ROLE, account);
    }
}
