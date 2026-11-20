// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../src/Bridge.sol";
import {StateManager} from "../../src/StateManager.sol";
import {Router} from "../../src/Router.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {ERC20Gateway} from "../../src/ERC20Gateway.sol";
import {UnmappedL1Token} from "../../src/Router.sol";
import {ETHGateway} from "../../src/ETHGateway.sol";
import {MockERC20} from "../fixtures/contracts/MockERC20.sol";
import {MockWETH} from "../fixtures/contracts/MockWETH.sol";
import {MockGnarkVerifier} from "../fixtures/contracts/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

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

    /// Guardians and the L2 deposit leaf carry the token id as a u32, so a wider id could never be appended.
    function testTokenMappingRejectsAnL2TokenIdWiderThanU32() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 token = new MockERC20("Wide", "WIDE");
        bytes32 wideId = bytes32(uint256(type(uint32).max) + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenIdOutOfRange.selector, wideId));
        router.setTokenMapping(address(token), wideId);
        assertFalse(router.isTokenMapped(address(token)));

        bytes32 widestId = bytes32(uint256(type(uint32).max));
        vm.prank(owner);
        router.setTokenMapping(address(token), widestId);
        assertEq(router.l1ToL2Token(address(token)), widestId);
    }

    /// The Guardians check a deposit's mapping at the append anchor, so re-pointing a mapped token or id would
    /// strand its unappended deposits at the head of the ordered queue.
    function testTokenMappingCannotBeRepointed() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 tokenA = new MockERC20("A", "A");
        MockERC20 tokenB = new MockERC20("B", "B");
        bytes32 idA = bytes32(uint256(1));
        bytes32 idB = bytes32(uint256(2));
        bytes32 ethId = bytes32(uint256(0x8888));
        vm.startPrank(owner);
        router.setTokenMapping(address(tokenA), idA);
        router.setTokenMapping(address(0), ethId);
        router.setTokenMapping(address(tokenA), idA);

        vm.expectRevert(abi.encodeWithSelector(Router.TokenMappingAlreadySet.selector, address(tokenA), idB));
        router.setTokenMapping(address(tokenA), idB);
        vm.expectRevert(abi.encodeWithSelector(Router.TokenMappingAlreadySet.selector, address(tokenB), idA));
        router.setTokenMapping(address(tokenB), idA);
        vm.expectRevert(abi.encodeWithSelector(Router.TokenMappingAlreadySet.selector, address(tokenB), ethId));
        router.setTokenMapping(address(tokenB), ethId);
        vm.expectRevert(abi.encodeWithSelector(Router.TokenMappingAlreadySet.selector, address(0), idB));
        router.setTokenMapping(address(0), idB);

        router.setTokenMapping(address(tokenB), idB);
        vm.stopPrank();
        assertEq(router.l1ToL2Token(address(tokenA)), idA);
        assertEq(router.l2ToL1Token(idA), address(tokenA));
        assertEq(router.l1ToL2Token(address(0)), ethId);
        assertEq(router.l2ToL1Token(idB), address(tokenB));
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

    /// bytes32(0) is the PSY L2 token id, so an unregistered mapping read as zero would credit a deposit to PSY.
    /// The Router is the single authority: it reverts before any gateway is entered, so no state changes anywhere.
    function testUnmappedTokenDepositIsRejected() public {
        (, Bridge bridge, Router router, ERC20Gateway erc20g, ETHGateway ethg, MockWETH weth) = _deployAll();
        MockERC20 token = new MockERC20("Unmapped", "UMP");
        _configureFlowToken(bridge, address(token));
        _configureFlowToken(bridge, address(0));
        token.mint(user, 1_000);
        vm.deal(user, 2 ether);

        assertFalse(router.isTokenMapped(address(token)));
        assertFalse(router.isTokenMapped(address(0)));

        vm.startPrank(user);
        token.approve(address(erc20g), 500);
        vm.expectRevert(abi.encodeWithSelector(UnmappedL1Token.selector, address(token)));
        router.deposit(address(token), 500, bytes32(uint256(42)), bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(UnmappedL1Token.selector, address(0)));
        router.deposit{value: 1 ether}(address(0), 1 ether, bytes32(uint256(7)), bytes32(uint256(2)));
        vm.stopPrank();

        assertEq(bridge.pendingDepositCount(), 0);
        assertEq(token.balanceOf(address(bridge)), 0);
        assertEq(weth.balanceOf(address(bridge)), 0);
    }

    /// Unmapped and one-way mapped pairs revert with the single Router error before any gateway or Bridge V6 state is touched.
    function test_router_rejects_unmapped_pair_with_v6_identity() public {
        (, Bridge bridge, Router router, ERC20Gateway erc20g,, MockWETH weth) = _deployAll();
        MockERC20 psy = new MockERC20("PSY", "PSY");
        MockERC20 usdt = new MockERC20("pUSDT", "pUSDT");
        MockERC20 unknown = new MockERC20("Unknown", "UNK");
        address[3] memory tokens = [address(psy), address(usdt), address(unknown)];
        for (uint256 i = 0; i < tokens.length; i++) {
            _configureFlowToken(bridge, tokens[i]);
            MockERC20(tokens[i]).mint(user, 1_000);
        }
        _configureFlowToken(bridge, address(0));
        vm.deal(user, 2 ether);

        vm.startPrank(owner);
        router.setTokenMapping(address(psy), bytes32(0));
        router.setTokenMapping(address(usdt), bytes32(uint256(4)));
        vm.stopPrank();

        // Unmapped ERC20 and unmapped native.
        _expectUnmappedDeposit(router, erc20g, address(unknown), 0);
        _expectUnmappedDeposit(router, erc20g, address(0), 1 ether);

        // setTokenMapping no longer re-points a mapped pair, so the one-way states below can only
        // predate the upgrade; they are written straight into storage to keep the deposit check covered.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.TokenMappingAlreadySet.selector, address(psy), bytes32(uint256(4))));
        router.setTokenMapping(address(psy), bytes32(uint256(4)));

        // One-way: usdt keeps its forward mapping, but id 4 resolves back to psy.
        _storeReverseMapping(router, bytes32(uint256(4)), address(psy));
        _expectUnmappedDeposit(router, erc20g, address(usdt), 0);

        // One-way native: forward id 9 is set, then another token holds id 9.
        vm.prank(owner);
        router.setTokenMapping(address(0), bytes32(uint256(9)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.TokenMappingAlreadySet.selector, address(unknown), bytes32(uint256(9))));
        router.setTokenMapping(address(unknown), bytes32(uint256(9)));
        _storeReverseMapping(router, bytes32(uint256(9)), address(unknown));
        _expectUnmappedDeposit(router, erc20g, address(0), 1 ether);

        assertEq(bridge.pendingDepositCount(), 0);
        assertEq(weth.balanceOf(address(bridge)), 0);
        assertEq(usdt.balanceOf(user), 1_000);
    }

    /// Router storage slot 3 is `l2ToL1Token` (forge inspect Router storageLayout).
    function _storeReverseMapping(Router router, bytes32 l2Token, address l1Token) internal {
        vm.store(address(router), keccak256(abi.encode(l2Token, uint256(3))), bytes32(uint256(uint160(l1Token))));
        assertEq(router.l2ToL1Token(l2Token), l1Token);
    }

    function _expectUnmappedDeposit(Router router, ERC20Gateway erc20g, address token, uint256 value) internal {
        vm.startPrank(user);
        if (token != address(0)) MockERC20(token).approve(address(erc20g), 500);
        vm.expectRevert(abi.encodeWithSelector(UnmappedL1Token.selector, token));
        router.deposit{value: value}(token, token == address(0) ? value : 500, bytes32(uint256(42)), bytes32(uint256(1)));
        vm.stopPrank();
    }
}
