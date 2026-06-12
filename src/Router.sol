// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ITokenGateway} from "./IGateway.sol";

interface IPsyAddressesProviderRouter {
    function ACL_MANAGER_ID() external view returns (bytes32);
    function ERC20_GATEWAY_ID() external view returns (bytes32);
    function ETH_GATEWAY_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
}

interface IPsyACLManagerRouter {
    function isRouterAdmin(address account) external view returns (bool);
}

contract Router is Initializable, OwnableUpgradeable {
    uint256 public constant VERSION = 1;

    address public addressesProvider;

    mapping(address => address) public tokenToGateway;
    mapping(address => bytes32) public l1ToL2Token;
    mapping(bytes32 => address) public l2ToL1Token;

    error ZeroAddress();
    error GatewayNotConfigured();
    error InvalidMsgValue();
    error OnlyRouterAdmin();

    modifier onlyRouterAdmin() {
        IPsyAddressesProviderRouter provider = IPsyAddressesProviderRouter(addressesProvider);
        address aclManager = provider.getAddress(provider.ACL_MANAGER_ID());
        if (!IPsyACLManagerRouter(aclManager).isRouterAdmin(msg.sender)) revert OnlyRouterAdmin();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address addressesProvider_) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
    }

    function getRevision() external pure returns (uint256) {
        return VERSION;
    }

    function setTokenGateway(address token, address gateway) external onlyRouterAdmin {
        if (token == address(0) || gateway == address(0)) revert ZeroAddress();
        tokenToGateway[token] = gateway;
    }

    function setTokenMapping(address l1Token, bytes32 l2Token) external onlyRouterAdmin {
        l1ToL2Token[l1Token] = l2Token;
        l2ToL1Token[l2Token] = l1Token;
    }

    function deposit(address token, uint256 amount, bytes32 shieldAddress, bytes32 noteSecretHash)
        external
        payable
        returns (uint32 index, bytes32 newRoot)
    {
        IPsyAddressesProviderRouter provider = IPsyAddressesProviderRouter(addressesProvider);
        address ethGateway = provider.getAddress(provider.ETH_GATEWAY_ID());
        address defaultERC20Gateway = provider.getAddress(provider.ERC20_GATEWAY_ID());

        if (token == address(0)) {
            if (ethGateway == address(0)) revert GatewayNotConfigured();
            if (msg.value != amount) revert InvalidMsgValue();
            return ITokenGateway(ethGateway).deposit{value: msg.value}(msg.sender, token, amount, shieldAddress, noteSecretHash);
        }

        if (msg.value != 0) revert InvalidMsgValue();

        address gateway = tokenToGateway[token];
        if (gateway == address(0)) {
            gateway = defaultERC20Gateway;
        }
        if (gateway == address(0)) revert GatewayNotConfigured();

        return ITokenGateway(gateway).deposit(msg.sender, token, amount, shieldAddress, noteSecretHash);
    }
}
