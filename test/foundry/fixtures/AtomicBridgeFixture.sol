// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Bridge} from "../../../src/Bridge.sol";
import {BridgeOpening} from "../../../src/BridgeOpening.sol";
import {StateManager} from "../../../src/StateManager.sol";
import {Router} from "../../../src/Router.sol";
import {PsyAddressesProvider} from "../../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../../src/PsyACLManager.sol";
import {MockGnarkVerifier} from "../../fixtures/contracts/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../../fixtures/contracts/TestERC1967Proxy.sol";
import {IEthereumRewardPayer} from "../../../src/IEthereumRewardPayer.sol";

// Orchestration-only payer; token accounting is covered by the payer owner's tests.
contract OpeningFixturePayer {
    address public stateManager;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    event ObservedReward(uint32 userId, uint256 amount, address recipient);

    function configure(address manager) external { stateManager = manager; }
    function setCallback(address target, bytes calldata data) external { callback = target; callbackData = data; }
    function payRewards(IEthereumRewardPayer.RewardClaim[] calldata claims) external {
        require(msg.sender == stateManager, "manager");
        if (callback != address(0)) (callbackSucceeded, callbackResult) = callback.call(callbackData);
        for (uint256 i; i < claims.length; ++i) emit ObservedReward(claims[i].userId, claims[i].amount, claims[i].recipient);
    }
}


// Mock proofs exercise orchestration only, never cryptographic acceptance.
abstract contract AtomicBridgeFixture is Test {
    bytes32 internal constant EMPTY_DEPOSIT_ROOT =
        0xe479b9bb36c3fc43b1e4dac93c0cde8e29332a714327ba72d65af5933a094e83;
    Bridge internal atomicBridge;
    StateManager internal manager;
    PsyAddressesProvider internal provider;
    bytes internal networkConfig;
    MockGnarkVerifier internal openingVerifier;
    OpeningFixturePayer internal openingPayer;

    struct Opening {
        uint256[8] proof;
        bytes opening;
    }

    function _deployAtomic(address owner, address proposer) internal {
        provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(new PsyAddressesProvider()), abi.encodeCall(PsyAddressesProvider.initialize, (owner)))));
        PsyACLManager acl = PsyACLManager(address(new TestERC1967Proxy(address(new PsyACLManager()), abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, proposer)))));
        openingVerifier = new MockGnarkVerifier();
        openingVerifier.setWithdrawalTokenPolicy(0, 1, address(0x1234), bytes32(uint256(1)), 0, 32, 32);
        openingVerifier.setWithdrawalTokenPolicy(0, 2, address(0x5678), bytes32(uint256(2)), 0, 32, 32);
        openingVerifier.setWithdrawalTokenPolicy(0, 3, address(0), bytes32(uint256(3)), 0, 32, 32);
        openingPayer = new OpeningFixturePayer();
        Bridge bridgeImpl = new Bridge();
        StateManager managerImpl = new StateManager();
        Router router = Router(address(new TestERC1967Proxy(address(new Router()), abi.encodeCall(Router.initialize, (owner, address(provider))))));
        address bridgeProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address managerProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(acl));
        provider.setAddress(provider.BRIDGE_ID(), bridgeProxy);
        provider.setAddress(provider.STATE_MANAGER_ID(), managerProxy);
        provider.setAddress(provider.ERC20_GATEWAY_ID(), owner);
        provider.setAddress(provider.ROUTER_ID(), address(router));
        vm.stopPrank();
        networkConfig = bytes.concat(
            abi.encode(uint32(1), uint64(42), uint32(524288), bytes32(uint256(7)), uint256(1)),
            abi.encode(uint8(0), block.chainid, bridgeProxy, managerProxy, uint64(0)), _rootWords(bytes32(0)),
            abi.encode(uint8(0), address(openingPayer), address(14), uint256(1), uint8(18), uint32(32), uint32(32))
        );
        atomicBridge = Bridge(payable(address(new TestERC1967Proxy(address(bridgeImpl), abi.encodeCall(Bridge.initialize, (owner, address(provider), networkConfig, uint8(0)))))));
        manager = StateManager(address(new TestERC1967Proxy(address(managerImpl), abi.encodeCall(StateManager.initialize, (owner, address(provider), uint8(0), networkConfig, address(openingVerifier))))));
        openingPayer.configure(address(manager));
        vm.startPrank(owner);
        atomicBridge.installWithdrawalToken(1, address(0x1234), bytes32(uint256(1)), 0, 32, 32);
        atomicBridge.installWithdrawalToken(2, address(0x5678), bytes32(uint256(2)), 0, 32, 32);
        atomicBridge.installWithdrawalToken(3, address(0), bytes32(uint256(3)), 0, 32, 32);
        vm.stopPrank();
    }

    function _rootWords(bytes32 root) internal pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }

    function _opening(uint64 endId, bytes32 endRoot, BridgeOpening.BridgeChainRow memory row, BridgeOpening.DepositLeaf[] memory deposits, BridgeOpening.WithdrawalBurnRecord[] memory withdrawals) internal view returns (Opening memory a) {
        a.opening = bytes.concat(
            abi.encode(uint256(4), atomicBridge.configHash(), endId), _rootWords(endRoot), _rootWords(bytes32(0)),
            abi.encode(uint256(1), deposits.length, withdrawals.length, uint256(0)),
            abi.encode(row.chainIndex, row.startCheckpointId), _rootWords(row.startCheckpointRoot),
            _rootWords(row.oldDepositRoot), _rootWords(row.newDepositRoot), abi.encode(row.oldCount, row.newCount)
        );
        for (uint256 i; i < deposits.length; ++i) a.opening = bytes.concat(a.opening, abi.encode(deposits[i]));
        for (uint256 i; i < withdrawals.length; ++i) {
            BridgeOpening.WithdrawalBurnRecord memory record = withdrawals[i];
            a.opening = bytes.concat(a.opening, abi.encode(uint256(1), record.chainIndex, record.userId, record.contractId, record.nonce, uint256(0), uint256(0), uint256(0), record.recipient, record.amount));
        }
        a.proof[0] = 1;
    }

    function _currentRow() internal view returns (BridgeOpening.BridgeChainRow memory) {
        return BridgeOpening.BridgeChainRow(0, uint32(manager.lastFinalizedCheckpointId()), manager.lastVerifiedCheckpointRoot(), atomicBridge.depositRoot(), atomicBridge.depositRoot(), uint32(atomicBridge.provedDepositCount()), uint32(atomicBridge.provedDepositCount()));
    }

    function _emptyOpening(uint64 endId, bytes32 endRoot) internal view returns (Opening memory) {
        return _opening(endId, endRoot, _currentRow(), new BridgeOpening.DepositLeaf[](0), new BridgeOpening.WithdrawalBurnRecord[](0));
    }

    function _withdrawalOpening(address recipient, uint32 tokenContractId, uint256 amount, bytes32 nonce) internal view returns (Opening memory) {
        BridgeOpening.WithdrawalBurnRecord[] memory records = new BridgeOpening.WithdrawalBurnRecord[](1);
        records[0] = BridgeOpening.WithdrawalBurnRecord(0, 0, tokenContractId, nonce, recipient, amount);
        uint64 endId = manager.lastFinalizedCheckpointId() + 1;
        return _opening(endId, bytes32(uint256(endId)), _currentRow(), new BridgeOpening.DepositLeaf[](0), records);
    }

    function _apply(Opening memory a) internal {
        manager.applyBridgeOpening(a.proof, a.opening);
    }
}
