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

error UnmappedL1Token(address token);

contract Router is Initializable, OwnableUpgradeable {
    uint256 public constant VERSION = 1;

    address public addressesProvider;

    mapping(address => address) public tokenToGateway;
    mapping(address => bytes32) public l1ToL2Token;
    mapping(bytes32 => address) public l2ToL1Token;
    /// Appended after the existing reverse map. A true flag reserves the L2 id
    /// even when its reverse word is address(0) (native ETH). Pre-upgrade pairs
    /// stay false; setTokenMapping reads them without writing them back.
    mapping(bytes32 => bool) public isL2TokenOccupied;

    error ZeroAddress();
    error GatewayNotConfigured();
    error InvalidMsgValue();
    error OnlyRouterAdmin();
    error NativeL2TokenZero();
    error L2TokenOccupied(bytes32 l2Token, address occupant);

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

    /// Occupancy is independent of the reverse word: native's reverse is
    /// address(0), and bytes32(0) is PSY's real id. A different L1 already
    /// holding `l2Token` reverts. The same pair is a no-op. A successful remap
    /// leaves the previous nonzero native id reserved and does not clear either direction.
    function setTokenMapping(address l1Token, bytes32 l2Token) external onlyRouterAdmin {
        if (l1Token == address(0) && l2Token == bytes32(0)) revert NativeL2TokenZero();
        if (isTokenMapped(l1Token) && l1ToL2Token[l1Token] == l2Token) return;
        (bool occupied, address occupant) = _l2Occupant(l2Token);
        if (occupied && occupant != l1Token) revert L2TokenOccupied(l2Token, occupant);

        if (l1Token == address(0)) {
            bytes32 previous = l1ToL2Token[address(0)];
            if (previous != bytes32(0)) isL2TokenOccupied[previous] = true;
        }
        l1ToL2Token[l1Token] = l2Token;
        l2ToL1Token[l2Token] = l1Token;
        isL2TokenOccupied[l2Token] = true;
    }

    /// Recorded occupancy wins, including a native holder of address(0).
    /// An unrecorded id is held by a nonzero reverse owner, or by native when
    /// this nonzero id is already native's forward. Id 0 is never inferred
    /// from native. The bool is required: address(0) is both "free" and native.
    function _l2Occupant(bytes32 l2Token) internal view returns (bool occupied, address holder) {
        if (isL2TokenOccupied[l2Token]) return (true, l2ToL1Token[l2Token]);
        address recorded = l2ToL1Token[l2Token];
        if (recorded != address(0)) return (true, recorded);
        if (l2Token != bytes32(0) && l1ToL2Token[address(0)] == l2Token) return (true, address(0));
        return (false, address(0));
    }

    /// bytes32(0) is a real L2 token id (PSY), so a mapping read needs the reverse check to mean "mapped".
    /// Native's unset forward is also zero, so it is mapped only when that forward is nonzero and reverses to native.
    function isTokenMapped(address l1Token) public view returns (bool) {
        bytes32 l2Token = l1ToL2Token[l1Token];
        if (l1Token == address(0)) return l2Token != bytes32(0) && l2ToL1Token[l2Token] == address(0);
        return l2ToL1Token[l2Token] == l1Token;
    }

    function deposit(address token, uint256 amount, bytes32 shieldAddress, bytes32 noteCommitment)
        external
        payable
        returns (uint32 index, bytes32 newRoot)
    {
        IPsyAddressesProviderRouter provider = IPsyAddressesProviderRouter(addressesProvider);
        address ethGateway = provider.getAddress(provider.ETH_GATEWAY_ID());
        address defaultERC20Gateway = provider.getAddress(provider.ERC20_GATEWAY_ID());

        // Single authority for the mapped-token check: revert here, before
        // any gateway is entered, so an unmapped deposit changes no state.
        // bytes32(0) is the PSY L2 token id, so an unregistered mapping would
        // otherwise credit this deposit to PSY.
        if (!isTokenMapped(token)) revert UnmappedL1Token(token);

        if (token == address(0)) {
            if (ethGateway == address(0)) revert GatewayNotConfigured();
            if (msg.value != amount) revert InvalidMsgValue();
            return ITokenGateway(ethGateway).deposit{value: msg.value}(msg.sender, token, amount, shieldAddress, noteCommitment);
        }

        if (msg.value != 0) revert InvalidMsgValue();

        address gateway = tokenToGateway[token];
        if (gateway == address(0)) {
            gateway = defaultERC20Gateway;
        }
        if (gateway == address(0)) revert GatewayNotConfigured();

        return ITokenGateway(gateway).deposit(msg.sender, token, amount, shieldAddress, noteCommitment);
    }
}
