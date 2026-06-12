// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract PsyAddressesProvider is Initializable, OwnableUpgradeable {
    uint256 public constant VERSION = 1;

    bytes32 public constant BRIDGE_ID = keccak256("BRIDGE");
    bytes32 public constant ACL_MANAGER_ID = keccak256("ACL_MANAGER");
    bytes32 public constant STATE_MANAGER_ID = keccak256("STATE_MANAGER");
    bytes32 public constant ROUTER_ID = keccak256("ROUTER");
    bytes32 public constant ERC20_GATEWAY_ID = keccak256("ERC20_GATEWAY");
    bytes32 public constant ETH_GATEWAY_ID = keccak256("ETH_GATEWAY");
    bytes32 public constant ZK_VERIFIER_ID = keccak256("ZK_VERIFIER");

    mapping(bytes32 => address) private _addresses;

    event AddressSet(bytes32 indexed id, address indexed oldAddress, address indexed newAddress);

    error ZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function getRevision() external pure returns (uint256) {
        return VERSION;
    }

    function getAddress(bytes32 id) external view returns (address) {
        return _addresses[id];
    }

    function setAddress(bytes32 id, address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        address oldAddress = _addresses[id];
        _addresses[id] = newAddress;
        emit AddressSet(id, oldAddress, newAddress);
    }
}
