// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BridgeOpening} from "./BridgeOpening.sol";
import {IAggregateVerifier} from "./IAggregateVerifier.sol";
import {IAggregateBridge} from "./IAggregateBridge.sol";
import {IEthereumRewardPayer} from "./IEthereumRewardPayer.sol";

interface IPsyAddressesProviderSM {
    function ACL_MANAGER_ID() external view returns (bytes32);
    function BRIDGE_ID() external view returns (bytes32);
    function ZK_VERIFIER_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
}

interface IPsyACLManagerSM {
    function isProposer(address account) external view returns (bool);
    function isStateManagerAdmin(address account) external view returns (bool);
}


contract StateManager is OwnableUpgradeable {
    uint256 public constant VERSION = 3;
    uint64 public constant BRIDGE_USER_ID = 524288;
    bytes32 internal constant FORCE_SET_STATE_HASH_DOMAIN = keccak256("PSY_STATE_MANAGER_FORCE_SET_STATE_V1");

    struct StateManagerContractState {
        uint64 lastFinalizedCheckpointId;
        bytes32 lastVerifiedCheckpointRoot;
        bytes32 lastVerifiedDepositTreeRoot;
        bytes32 lastVerifiedWithdrawalTreeRoot;
        bytes32 withdrawalSubtreeRoot;
    }

    address public addressesProvider;
    uint8 public l1ChainIndex;

    uint64 public lastFinalizedCheckpointId;
    bytes32 public lastVerifiedCheckpointRoot;
    bytes32 public lastVerifiedDepositTreeRoot;
    bytes32 public lastVerifiedWithdrawalTreeRoot;
    bytes32 public withdrawalSubtreeRoot;
    // Reserved storage slots kept for upgrade safety.
    mapping(bytes32 => bool) public knownDepositSubtreeRoots;
    mapping(bytes32 => bool) public knownWithdrawalSubtreeRoots;
    bytes private _aggregateConfig;
    bytes32 public configHash;
    address public aggregateVerifier;
    address public aggregateBridge;
    uint32 public depositCount;
    bytes32 public depositSubtreeRoot;
    bool private _applyingAggregate;

    event AggregateFinalized(bytes32 indexed statementB, uint64 endCheckpointId, bytes32 endCheckpointRoot, bytes32 localDepositRoot, uint32 localDepositCount, bytes32 localWithdrawalRoot);
    error UnauthorizedInitializer();
    error AggregateReentrancy();

    event Finalized(
        uint64 indexed newLastFinalizedCheckpointId,
        bytes32 indexed newLastVerifiedCheckpointRoot,
        bytes32 depositTreeRoot,
        bytes32 withdrawalTreeRoot
    );
    event ForceSetState(
        bytes32 indexed previousStateHash,
        bytes32 indexed newStateHash,
        uint64 lastFinalizedCheckpointId,
        bytes32 lastVerifiedCheckpointRoot,
        bytes32 lastVerifiedDepositTreeRoot,
        bytes32 lastVerifiedWithdrawalTreeRoot,
        bytes32 withdrawalSubtreeRoot
    );

    error OnlyBridge();
    error OnlyProposer();
    error ZeroAddress();
    error VerifierNotSet();
    error InvalidProof();
    error InvalidCheckpointContinuity();
    error InvalidDepositMerkleProof();
    error InvalidWithdrawalMerkleProof();
    error InvalidProvenChainIndex();
    error WithdrawalBootstrapExpired();

    error UnauthorizedStateManagerAdmin();
    error InvalidForceSetState();
    error UnexpectedCurrentState(bytes32 expectedStateHash, bytes32 actualStateHash);

    modifier onlyProposer() {
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        address aclManager = provider.getAddress(provider.ACL_MANAGER_ID());
        if (!IPsyACLManagerSM(aclManager).isProposer(msg.sender)) revert OnlyProposer();
        _;
    }
    modifier onlyStateManagerAdmin() {
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        address aclManager = provider.getAddress(provider.ACL_MANAGER_ID());
        if (!IPsyACLManagerSM(aclManager).isStateManagerAdmin(msg.sender)) {
            revert UnauthorizedStateManagerAdmin();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_, address addressesProvider_, uint8 l1ChainIndex_,
        bytes calldata networkConfig, address verifier
    ) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        l1ChainIndex = l1ChainIndex_;
        BridgeOpening.ChainConfig memory chain = _initializeAggregation(networkConfig, verifier);
        lastFinalizedCheckpointId = chain.bootstrapId;
        lastVerifiedCheckpointRoot = chain.bootstrapRoot;
    }


    function _initializeAggregation(bytes calldata networkConfig, address verifier) internal returns (BridgeOpening.ChainConfig memory chain) {
        if (configHash != bytes32(0) || verifier.code.length == 0) revert VerifierNotSet();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(networkConfig);
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        address bridge = provider.getAddress(provider.BRIDGE_ID());
        chain = BridgeOpening.localChain(config, l1ChainIndex, bridge, address(this));
        _aggregateConfig = networkConfig;
        configHash = config.configHash;
        aggregateVerifier = verifier;
        aggregateBridge = bridge;
    }

    function getRevision() external pure virtual returns (uint256) {
        return VERSION;
    }

    function forceSetState(
        StateManagerContractState calldata expected,
        StateManagerContractState calldata target
    ) external onlyStateManagerAdmin {
        bytes32 actualStateHash = _forceSetStateHash(
            StateManagerContractState({
                lastFinalizedCheckpointId: lastFinalizedCheckpointId,
                lastVerifiedCheckpointRoot: lastVerifiedCheckpointRoot,
                lastVerifiedDepositTreeRoot: lastVerifiedDepositTreeRoot,
                lastVerifiedWithdrawalTreeRoot: lastVerifiedWithdrawalTreeRoot,
                withdrawalSubtreeRoot: withdrawalSubtreeRoot
            })
        );
        bytes32 targetStateHash = _forceSetStateHash(target);
        if (actualStateHash == targetStateHash) return;

        bytes32 expectedStateHash = _forceSetStateHash(expected);
        if (actualStateHash != expectedStateHash) {
            revert UnexpectedCurrentState(expectedStateHash, actualStateHash);
        }
        if (target.lastFinalizedCheckpointId > expected.lastFinalizedCheckpointId) {
            revert InvalidForceSetState();
        }

        lastFinalizedCheckpointId = target.lastFinalizedCheckpointId;
        lastVerifiedCheckpointRoot = target.lastVerifiedCheckpointRoot;
        lastVerifiedDepositTreeRoot = target.lastVerifiedDepositTreeRoot;
        lastVerifiedWithdrawalTreeRoot = target.lastVerifiedWithdrawalTreeRoot;
        withdrawalSubtreeRoot = target.withdrawalSubtreeRoot;

        emit ForceSetState(
            actualStateHash,
            targetStateHash,
            target.lastFinalizedCheckpointId,
            target.lastVerifiedCheckpointRoot,
            target.lastVerifiedDepositTreeRoot,
            target.lastVerifiedWithdrawalTreeRoot,
            target.withdrawalSubtreeRoot
        );
    }

    function _forceSetStateHash(StateManagerContractState memory state_) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FORCE_SET_STATE_HASH_DOMAIN,
                state_.lastFinalizedCheckpointId,
                state_.lastVerifiedCheckpointRoot,
                state_.lastVerifiedDepositTreeRoot,
                state_.lastVerifiedWithdrawalTreeRoot,
                state_.withdrawalSubtreeRoot
            )
        );
    }

    function finalizeCheckpointAggregate(uint256[8] calldata proof, bytes calldata completeOpening) external onlyProposer {
        if (_applyingAggregate) revert AggregateReentrancy();
        if (configHash == bytes32(0) || aggregateVerifier.code.length == 0) revert VerifierNotSet();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(_aggregateConfig);
        BridgeOpening.localChain(config, l1ChainIndex, aggregateBridge, address(this));
        BridgeOpening.BOpening memory b = BridgeOpening.readB(completeOpening, config);
        IAggregateVerifier(aggregateVerifier).verifyProof(proof, BridgeOpening.proofInputs(b.statementB));
        uint256 ordinal = BridgeOpening.chainOrdinal(config, l1ChainIndex);
        BridgeOpening.ChainStart memory start = b.a.starts[ordinal];
        if (start.startCheckpointId != lastFinalizedCheckpointId || start.startCheckpointRoot != lastVerifiedCheckpointRoot) revert InvalidCheckpointContinuity();
        IAggregateBridge bridge = IAggregateBridge(aggregateBridge);
        BridgeOpening.ChainEnd memory end = b.ends[ordinal];
        if (bridge.configHash() != configHash || bridge.depositRoot() != end.depositRoot || bridge.provedDepositCount() != end.depositCount) revert InvalidDepositMerkleProof();
        bool localWithdrawal;
        for (uint256 i; i < b.withdrawals.length; ++i) {
            if (b.withdrawals[i].chainIndex == l1ChainIndex) { localWithdrawal = true; break; }
        }
        bool localRewards = l1ChainIndex == config.ethereumIndex && b.rewards.length != 0;
        if (lastFinalizedCheckpointId == b.a.endCheckpointId && !localWithdrawal && !localRewards) {
            emit AggregateFinalized(b.statementB, b.a.endCheckpointId, b.a.endCheckpointRoot, end.depositRoot, end.depositCount, end.withdrawalRoot);
            return;
        }
        _applyingAggregate = true;
        if (lastFinalizedCheckpointId != b.a.endCheckpointId) {
            lastFinalizedCheckpointId = b.a.endCheckpointId;
            lastVerifiedCheckpointRoot = b.a.endCheckpointRoot;
            depositSubtreeRoot = end.depositRoot;
            depositCount = end.depositCount;
            withdrawalSubtreeRoot = end.withdrawalRoot;
        }
        if (localWithdrawal) bridge.registerAggregateWithdrawals(b.withdrawals);
        if (localRewards) {
            IEthereumRewardPayer payer = IEthereumRewardPayer(config.rewardPayer);
            if (payer.configHash() != configHash || payer.stateManager() != address(this) || payer.ethereumChainId() != block.chainid) revert InvalidProvenChainIndex();
            payer.payRewards(b.rewards);
        }
        _applyingAggregate = false;
        emit AggregateFinalized(b.statementB, b.a.endCheckpointId, b.a.endCheckpointRoot, end.depositRoot, end.depositCount, end.withdrawalRoot);
    }
}
