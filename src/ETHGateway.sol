// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function deposit() external payable;
}

interface IBridgeGateway {
    function recordDepositFromGateway(
        address token,
        bytes32 l2TokenContractId,
        uint256 amount,
        bytes32 shieldAddress,
        bytes32 noteCommitment
    )
        external
        returns (uint32 index, bytes32 newRoot);
}

interface IPsyAddressesProviderGateway {
    function BRIDGE_ID() external view returns (bytes32);
    function ROUTER_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
}

interface IRouterBridgeView {
    function l1ToL2Token(address l1Token) external view returns (bytes32);
}

contract ETHGateway is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    uint256 public constant VERSION = 1;

    address public addressesProvider;
    address public weth;

    error OnlyRouter();
    error ZeroAddress();
    error InvalidMsgValue();
    error BridgeNotConfigured();

    modifier onlyRouter() {
        IPsyAddressesProviderGateway provider = IPsyAddressesProviderGateway(addressesProvider);
        if (msg.sender != provider.getAddress(provider.ROUTER_ID())) revert OnlyRouter();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address addressesProvider_, address weth_) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        weth = weth_;
    }

    function getRevision() external pure returns (uint256) {
        return VERSION;
    }

    function setWETH(address newWeth) external onlyOwner {
        if (newWeth == address(0)) revert ZeroAddress();
        weth = newWeth;
    }

    function deposit(address depositor, address token, uint256 amount, bytes32 shieldAddress, bytes32 noteCommitment)
        external
        payable
        onlyRouter
        returns (uint32 index, bytes32 newRoot)
    {
        IPsyAddressesProviderGateway provider = IPsyAddressesProviderGateway(addressesProvider);
        address bridgeAddr = provider.getAddress(provider.BRIDGE_ID());
        if (bridgeAddr == address(0)) revert BridgeNotConfigured();

        address router = provider.getAddress(provider.ROUTER_ID());
        bytes32 l2TokenContractId = IRouterBridgeView(router).l1ToL2Token(token);

        if (msg.value != amount) revert InvalidMsgValue();
        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).safeTransfer(bridgeAddr, amount);
        depositor;
        return IBridgeGateway(bridgeAddr).recordDepositFromGateway(
            token, l2TokenContractId, amount, shieldAddress, noteCommitment
        );
    }
}
