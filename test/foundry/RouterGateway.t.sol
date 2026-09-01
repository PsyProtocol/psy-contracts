// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {StateManager} from "../../src/StateManager.sol";
import {Router} from "../../src/Router.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {ERC20Gateway} from "../../src/ERC20Gateway.sol";
import {ETHGateway} from "../../src/ETHGateway.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {MockWETH} from "../../src/MockWETH.sol";
import {MockGnarkVerifier} from "../../src/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../../src/TestERC1967Proxy.sol";

contract RouterGatewayTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);

    function _deployAddressesProvider() internal returns (PsyAddressesProvider provider) {
        PsyAddressesProvider impl = new PsyAddressesProvider();
        bytes memory initData = abi.encodeCall(PsyAddressesProvider.initialize, (owner));
        provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployACL() internal returns (PsyACLManager acl) {
        PsyACLManager impl = new PsyACLManager();
        bytes memory initData = abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, owner));
        acl = PsyACLManager(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployStateManager(PsyAddressesProvider provider) internal returns (StateManager sm) {
        StateManager impl = new StateManager();
        bytes memory initData = abi.encodeCall(StateManager.initialize, (owner, address(provider), uint8(0)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        sm = StateManager(address(proxy));
    }

    function _deployRouter(PsyAddressesProvider provider) internal returns (Router router) {
        Router impl = new Router();
        bytes memory initData = abi.encodeCall(Router.initialize, (owner, address(provider)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        router = Router(address(proxy));
    }

    function _deployERC20Gateway(PsyAddressesProvider provider) internal returns (ERC20Gateway erc20g) {
        ERC20Gateway impl = new ERC20Gateway();
        bytes memory initData = abi.encodeCall(ERC20Gateway.initialize, (owner, address(provider)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        erc20g = ERC20Gateway(address(proxy));
    }

    function _deployETHGateway(PsyAddressesProvider provider, MockWETH weth) internal returns (ETHGateway ethg) {
        ETHGateway impl = new ETHGateway();
        bytes memory initData = abi.encodeCall(ETHGateway.initialize, (owner, address(provider), address(weth)));
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        ethg = ETHGateway(payable(address(proxy)));
    }

    function _deployBridge(
        PsyAddressesProvider provider,
        address depositBatchVerifier,
        address withdrawalClaimVerifier
    ) internal returns (Bridge bridge) {
        Bridge impl = new Bridge();
        bytes memory initData = abi.encodeCall(
            Bridge.initialize,
            (owner, address(provider), depositBatchVerifier, withdrawalClaimVerifier)
        );
        TestERC1967Proxy proxy = new TestERC1967Proxy(address(impl), initData);
        bridge = Bridge(payable(address(proxy)));
    }

    function _configureFlowToken(Bridge bridge, address token) internal {
        Bridge.TokenFlowConfig memory config = Bridge.TokenFlowConfig({
            minDepositAmount: 1,
            depositCap: 100 ether,
            smallWithdrawalMax: 1 ether,
            mediumWithdrawalMax: 5 ether,
            totalWithdrawalCap: 10 ether,
            smallWithdrawalDelay: 0,
            mediumWithdrawalDelay: 0,
            largeWithdrawalDelay: 0,
            configured: true
        });
        bytes32 expectedConfigHash = bridge.getTokenFlowConfigHash(token);
        vm.prank(owner);
        bridge.setTokenFlowConfig(token, config, expectedConfigHash);
    }

    function _deployAll()
        internal
        returns (StateManager sm, Bridge bridge, Router router, ERC20Gateway erc20g, ETHGateway ethg, MockWETH weth)
    {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyACLManager acl = _deployACL();
        sm = _deployStateManager(provider);
        router = _deployRouter(provider);
        weth = new MockWETH();
        erc20g = _deployERC20Gateway(provider);
        ethg = _deployETHGateway(provider, weth);
        MockGnarkVerifier verifier = new MockGnarkVerifier();
        bridge = _deployBridge(provider, address(verifier), address(verifier));

        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(verifier));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.ROUTER_ID(), address(router));
        provider.setAddress(provider.BRIDGE_ID(), address(bridge));
        provider.setAddress(provider.ERC20_GATEWAY_ID(), address(erc20g));
        provider.setAddress(provider.ETH_GATEWAY_ID(), address(ethg));
        vm.stopPrank();
    }

    function testRouterERC20DepositPath() public {
        (, Bridge bridge, Router router, ERC20Gateway erc20g,,) = _deployAll();
        MockERC20 token = new MockERC20("Mock", "MOCK");
        _configureFlowToken(bridge, address(token));
        vm.prank(owner);
        router.setTokenMapping(address(token), bytes32(uint256(0x1234)));
        token.mint(user, 1_000);

        vm.startPrank(user);
        token.approve(address(erc20g), 500);
        router.deposit(address(token), 500, bytes32(uint256(42)), bytes32(uint256(1)));
        vm.stopPrank();

        assertEq(token.balanceOf(address(bridge)), 500);
        assertEq(bridge.pendingDepositCount(), 1);
    }

    function testRouterETHDepositPath() public {
        (, Bridge bridge, Router router,, ETHGateway ethg, MockWETH weth) = _deployAll();
        _configureFlowToken(bridge, address(0));
        vm.prank(owner);
        router.setTokenMapping(address(0), bytes32(uint256(0x8888)));

        vm.deal(user, 2 ether);

        vm.prank(user);
        router.deposit{value: 1 ether}(address(0), 1 ether, bytes32(uint256(7)), bytes32(uint256(2)));

        assertEq(weth.balanceOf(address(bridge)), 1 ether);
        assertEq(bridge.pendingDepositCount(), 1);
        assertEq(ethg.weth(), address(weth));
    }
}
