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

    /// An L2 id already held by native cannot be given to an ERC20. The
    /// rejected call changes neither direction, and native deposits still use it.
    function testSharedL2IdIsRejectedAndStateUnchanged() public {
        (, Bridge bridge, Router router, ERC20Gateway erc20g,, MockWETH weth) = _deployAll();
        MockERC20 token = new MockERC20("Reassigned", "RSN");
        bytes32 sharedId = bytes32(uint256(0x8888));
        _configureFlowToken(bridge, address(0));
        _configureFlowToken(bridge, address(token));
        token.mint(user, 1_000);
        vm.deal(user, 2 ether);

        vm.prank(owner);
        router.setTokenMapping(address(0), sharedId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, sharedId, address(0)));
        router.setTokenMapping(address(token), sharedId);

        assertEq(router.l1ToL2Token(address(0)), sharedId);
        assertEq(router.l2ToL1Token(sharedId), address(0));
        assertEq(router.l1ToL2Token(address(token)), bytes32(0));
        assertTrue(router.isTokenMapped(address(0)));
        assertFalse(router.isTokenMapped(address(token)));

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(UnmappedL1Token.selector, address(token)));
        router.deposit(address(token), 500, bytes32(uint256(42)), bytes32(uint256(1)));
        router.deposit{value: 1 ether}(address(0), 1 ether, bytes32(uint256(7)), bytes32(uint256(2)));
        vm.stopPrank();

        assertEq(bridge.pendingDepositCount(), 1);
        assertEq(token.balanceOf(address(bridge)), 0);
        assertEq(weth.balanceOf(address(bridge)), 1 ether);
    }

    function testErc20CannotTakeAnotherErc20L2Id() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 first = new MockERC20("First", "FST");
        MockERC20 second = new MockERC20("Second", "SND");
        bytes32 sharedId = bytes32(uint256(0x1234));

        vm.prank(owner);
        router.setTokenMapping(address(first), sharedId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, sharedId, address(first)));
        router.setTokenMapping(address(second), sharedId);

        assertEq(router.l1ToL2Token(address(first)), sharedId);
        assertEq(router.l2ToL1Token(sharedId), address(first));
        assertEq(router.l1ToL2Token(address(second)), bytes32(0));
        assertFalse(router.isL2TokenOccupied(bytes32(0)));
    }

    function testNativeCannotTakeAnErc20L2Id() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 token = new MockERC20("Held", "HLD");
        bytes32 sharedId = bytes32(uint256(0x1234));

        vm.prank(owner);
        router.setTokenMapping(address(token), sharedId);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, sharedId, address(token)));
        router.setTokenMapping(address(0), sharedId);

        assertEq(router.l1ToL2Token(address(token)), sharedId);
        assertEq(router.l2ToL1Token(sharedId), address(token));
        assertEq(router.l1ToL2Token(address(0)), bytes32(0));
        assertFalse(router.isTokenMapped(address(0)));
    }

    function testFirstNonzeroNativeMappingSucceeds() public {
        (,, Router router,,,) = _deployAll();
        bytes32 nativeId = bytes32(uint256(0x8888));

        vm.prank(owner);
        router.setTokenMapping(address(0), nativeId);

        assertEq(router.l1ToL2Token(address(0)), nativeId);
        assertEq(router.l2ToL1Token(nativeId), address(0));
        assertTrue(router.isL2TokenOccupied(nativeId));
        assertTrue(router.isTokenMapped(address(0)));
        assertFalse(router.isL2TokenOccupied(bytes32(0)));
    }

    /// Id 0 is PSY's. The first native mapping must not reserve it.
    function testNativeMappingLeavesPsyZeroIdFree() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 psy = new MockERC20("Psy", "PSY");
        MockERC20 other = new MockERC20("Other", "OTH");
        bytes32 nativeId = bytes32(uint256(0x8888));

        vm.startPrank(owner);
        router.setTokenMapping(address(0), nativeId);
        router.setTokenMapping(address(psy), bytes32(0));
        vm.stopPrank();

        assertEq(router.l1ToL2Token(address(0)), nativeId);
        assertEq(router.l2ToL1Token(nativeId), address(0));
        assertTrue(router.isL2TokenOccupied(nativeId));
        assertEq(router.l1ToL2Token(address(psy)), bytes32(0));
        assertEq(router.l2ToL1Token(bytes32(0)), address(psy));
        assertTrue(router.isL2TokenOccupied(bytes32(0)));
        assertTrue(router.isTokenMapped(address(psy)));
        assertTrue(router.isTokenMapped(address(0)));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, bytes32(0), address(psy)));
        router.setTokenMapping(address(other), bytes32(0));

        assertEq(router.l2ToL1Token(bytes32(0)), address(psy));
        assertFalse(router.isTokenMapped(address(other)));
    }

    function testNativeZeroIdIsRejected() public {
        (,, Router router,,,) = _deployAll();

        vm.prank(owner);
        vm.expectRevert(Router.NativeL2TokenZero.selector);
        router.setTokenMapping(address(0), bytes32(0));

        assertEq(router.l1ToL2Token(address(0)), bytes32(0));
        assertEq(router.l2ToL1Token(bytes32(0)), address(0));
        assertFalse(router.isL2TokenOccupied(bytes32(0)));
        assertFalse(router.isTokenMapped(address(0)));
    }

    function testSamePairIsANoOpWithoutOccupancyWrites() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 token = new MockERC20("Same", "SAME");
        bytes32 tokenId = bytes32(uint256(0x1234));
        bytes32 nativeId = bytes32(uint256(0x8888));

        vm.startPrank(owner);
        router.setTokenMapping(address(token), tokenId);
        router.setTokenMapping(address(0), nativeId);

        vm.record();
        router.setTokenMapping(address(token), tokenId);
        router.setTokenMapping(address(0), nativeId);
        vm.stopPrank();

        (, bytes32[] memory writes) = vm.accesses(address(router));
        assertEq(writes.length, 0);
        assertEq(router.l1ToL2Token(address(token)), tokenId);
        assertEq(router.l1ToL2Token(address(0)), nativeId);
        assertTrue(router.isL2TokenOccupied(tokenId));
        assertTrue(router.isL2TokenOccupied(nativeId));
    }

    function testLegacyMappingsAreReadWithoutBackfill() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 token = new MockERC20("Legacy", "LGC");
        MockERC20 challenger = new MockERC20("Challenger", "CHG");
        bytes32 legacyId = bytes32(uint256(0x1234));
        bytes32 nativeId = bytes32(uint256(0x8888));

        vm.store(address(router), keccak256(abi.encode(address(token), uint256(2))), legacyId);
        vm.store(address(router), keccak256(abi.encode(legacyId, uint256(3))), bytes32(uint256(uint160(address(token)))));
        vm.store(address(router), keccak256(abi.encode(address(0), uint256(2))), nativeId);
        assertFalse(router.isL2TokenOccupied(legacyId));
        assertFalse(router.isL2TokenOccupied(nativeId));

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, legacyId, address(token)));
        router.setTokenMapping(address(challenger), legacyId);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, nativeId, address(0)));
        router.setTokenMapping(address(challenger), nativeId);

        vm.record();
        router.setTokenMapping(address(token), legacyId);
        router.setTokenMapping(address(0), nativeId);
        vm.stopPrank();

        (, bytes32[] memory writes) = vm.accesses(address(router));
        assertEq(writes.length, 0);
        assertFalse(router.isL2TokenOccupied(legacyId));
        assertFalse(router.isL2TokenOccupied(nativeId));
        assertEq(router.l2ToL1Token(legacyId), address(token));
        assertEq(router.l2ToL1Token(nativeId), address(0));
    }

    /// A pre-upgrade native pair has no occupancy flag. Moving it to a free id
    /// reserves the old id; its reverse word stays address(0).
    function testLegacyNativeRemapReservesOldId() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 other = new MockERC20("Other", "OTH");
        bytes32 legacyNativeId = bytes32(uint256(0x8888));
        bytes32 newNativeId = bytes32(uint256(0x9999));

        vm.store(address(router), keccak256(abi.encode(address(0), uint256(2))), legacyNativeId);
        assertTrue(router.isTokenMapped(address(0)));
        assertFalse(router.isL2TokenOccupied(legacyNativeId));
        assertEq(router.l2ToL1Token(legacyNativeId), address(0));

        vm.prank(owner);
        router.setTokenMapping(address(0), newNativeId);

        assertEq(router.l1ToL2Token(address(0)), newNativeId);
        assertEq(router.l2ToL1Token(newNativeId), address(0));
        assertTrue(router.isL2TokenOccupied(newNativeId));
        assertTrue(router.isL2TokenOccupied(legacyNativeId));
        assertEq(router.l2ToL1Token(legacyNativeId), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, legacyNativeId, address(0)));
        router.setTokenMapping(address(other), legacyNativeId);

        assertEq(router.l1ToL2Token(address(other)), bytes32(0));
        assertEq(router.l1ToL2Token(address(0)), newNativeId);
        assertTrue(router.isL2TokenOccupied(legacyNativeId));
    }

    function testRemapLeavesPreviousL2IdOccupied() public {
        (,, Router router,,,) = _deployAll();
        MockERC20 token = new MockERC20("Moving", "MOV");
        MockERC20 other = new MockERC20("Other", "OTH");
        bytes32 firstId = bytes32(uint256(0x1111));
        bytes32 secondId = bytes32(uint256(0x2222));
        bytes32 firstNativeId = bytes32(uint256(0x8888));
        bytes32 secondNativeId = bytes32(uint256(0x9999));

        vm.startPrank(owner);
        router.setTokenMapping(address(token), firstId);
        router.setTokenMapping(address(token), secondId);
        router.setTokenMapping(address(0), firstNativeId);
        router.setTokenMapping(address(0), secondNativeId);
        vm.stopPrank();

        assertEq(router.l1ToL2Token(address(token)), secondId);
        assertEq(router.l2ToL1Token(firstId), address(token));
        assertTrue(router.isL2TokenOccupied(firstId));
        assertEq(router.l1ToL2Token(address(0)), secondNativeId);
        assertEq(router.l2ToL1Token(firstNativeId), address(0));
        assertTrue(router.isL2TokenOccupied(firstNativeId));

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, firstId, address(token)));
        router.setTokenMapping(address(other), firstId);
        vm.expectRevert(abi.encodeWithSelector(Router.L2TokenOccupied.selector, firstNativeId, address(0)));
        router.setTokenMapping(address(other), firstNativeId);
        router.setTokenMapping(address(0), firstNativeId);
        vm.stopPrank();

        assertEq(router.l1ToL2Token(address(0)), firstNativeId);
        assertTrue(router.isL2TokenOccupied(secondNativeId));
        assertEq(router.l2ToL1Token(secondNativeId), address(0));
    }

    /// PSY owns id 0. That binding must not make an unset native deposit look mapped.
    function testPsyZeroIdDoesNotMapNative() public {
        (, Bridge bridge, Router router,,,) = _deployAll();
        MockERC20 psy = new MockERC20("Psy", "PSY");
        _configureFlowToken(bridge, address(0));

        vm.prank(owner);
        router.setTokenMapping(address(psy), bytes32(0));

        assertTrue(router.isTokenMapped(address(psy)));
        assertTrue(router.isL2TokenOccupied(bytes32(0)));
        assertFalse(router.isTokenMapped(address(0)));
    }
}
