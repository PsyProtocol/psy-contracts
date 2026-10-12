// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BridgeOpening} from "./BridgeOpening.sol";
import {IAggregateVerifier} from "./IAggregateVerifier.sol";
import {IEthereumRewardPayer} from "./IEthereumRewardPayer.sol";
import {IAggregateBridge} from "./IAggregateBridge.sol";

interface IPsyAddressesProviderSM {
    function ACL_MANAGER_ID() external view returns (bytes32);
    function BRIDGE_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
}

interface IPsyACLManagerSM {
    function isProposer(address account) external view returns (bool);
    function isStateManagerAdmin(address account) external view returns (bool);
}


contract StateManager is OwnableUpgradeable {
    uint256 public constant VERSION = 4;
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
    address private _reservedAggregateVerifier;
    address public aggregateBridge;
    uint32 public depositCount;
    bytes32 public depositSubtreeRoot;
    bool private _applyingAggregate;
    address private _reservedFinalizeVerifier;
    address private _reservedDepositVerifier;
    address private _reservedWithdrawalVerifier;
    address private _reservedRewardVerifier;
    mapping(uint64 => ImportedOpeningEndpoint) private _reservedOpeningEndpoints;

    struct ImportedOpeningEndpoint {
        bytes32 digest;
        bool isApplied;
    }

    address public openingVerifier;
    mapping(bytes32 => bool) public appliedOpenings;

    event WithdrawalAggregateApplied(bytes32 indexed openingDigest, uint64 endCheckpointId, bytes32 endCheckpointRoot);
    event RewardAggregateApplied(bytes32 indexed openingDigest, uint64 endCheckpointId, bytes32 endCheckpointRoot);
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
        bytes calldata networkConfig, address openingVerifier_
    ) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        l1ChainIndex = l1ChainIndex_;
        BridgeOpening.ChainConfig memory chain = _initializeAggregation(networkConfig, openingVerifier_);
        lastFinalizedCheckpointId = chain.bootstrapId;
        lastVerifiedCheckpointRoot = chain.bootstrapRoot;
    }


    function _initializeAggregation(bytes calldata networkConfig, address openingVerifier_) internal returns (BridgeOpening.ChainConfig memory chain) {
        if (configHash != bytes32(0) || openingVerifier_.code.length == 0) revert VerifierNotSet();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(networkConfig);
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        address bridge = provider.getAddress(provider.BRIDGE_ID());
        chain = BridgeOpening.localChain(config, l1ChainIndex, bridge, address(this));
        _aggregateConfig = networkConfig;
        configHash = config.configHash;
        openingVerifier = openingVerifier_;
        aggregateBridge = bridge;
    }

    function getRevision() external pure virtual returns (uint256) {
        return VERSION;
    }

    function forceSetState(
        StateManagerContractState calldata expected,
        StateManagerContractState calldata target
    ) external onlyStateManagerAdmin {
        if (_applyingAggregate) revert AggregateReentrancy();
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

    function applyingAggregate() external view returns (bool) {
        return _applyingAggregate;
    }

    function applyBridgeOpening(uint256[8] calldata proof, bytes calldata opening) external onlyProposer {
        if (_applyingAggregate) revert AggregateReentrancy();
        if (configHash == bytes32(0) || openingVerifier.code.length == 0) revert VerifierNotSet();
        _applyingAggregate = true;
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(_aggregateConfig);
        BridgeOpening.localChain(config, l1ChainIndex, aggregateBridge, address(this));
        BridgeOpening.BridgeOpeningBody memory a = BridgeOpening.readBridgeOpening(opening, config);
        IAggregateBridge bridge = IAggregateBridge(aggregateBridge);
        if (bridge.configHash() != configHash) revert InvalidDepositMerkleProof();
        if (!appliedOpenings[a.openingDigest]) {
            if (_zeroProof(proof)) revert InvalidProof();
            BridgeOpening.BridgeChainRow memory row = a.chains[BridgeOpening.chainOrdinal(config, l1ChainIndex)];
            if (row.startCheckpointId != lastFinalizedCheckpointId || row.startCheckpointRoot != lastVerifiedCheckpointRoot) revert InvalidCheckpointContinuity();
            if (row.oldDepositRoot != bridge.depositRoot() || row.oldCount != bridge.provedDepositCount()) revert InvalidDepositMerkleProof();
            if (a.endCheckpointId == row.startCheckpointId && (row.oldDepositRoot != row.newDepositRoot || row.oldCount != row.newCount)) revert InvalidDepositMerkleProof();
            IAggregateVerifier(openingVerifier).verifyProof(proof, BridgeOpening.proofInputs(a.openingDigest));
            bridge.applyDepositAggregate(row, a.deposits, a.openingDigest);
            if (a.endCheckpointId > lastFinalizedCheckpointId) {
                lastFinalizedCheckpointId = a.endCheckpointId;
                lastVerifiedCheckpointRoot = a.endCheckpointRoot;
                emit Finalized(a.endCheckpointId, a.endCheckpointRoot, lastVerifiedDepositTreeRoot, lastVerifiedWithdrawalTreeRoot);
            }
            depositSubtreeRoot = row.newDepositRoot;
            depositCount = row.newCount;
            appliedOpenings[a.openingDigest] = true;
        }
        bridge.applyWithdrawals(a.withdrawals);
        emit WithdrawalAggregateApplied(a.openingDigest, a.endCheckpointId, a.endCheckpointRoot);
        if (l1ChainIndex == config.ethereumIndex) {
            if (a.rewards.length != 0) IEthereumRewardPayer(config.rewardPayer).payRewards(a.rewards);
            emit RewardAggregateApplied(a.openingDigest, a.endCheckpointId, a.endCheckpointRoot);
        }
        _applyingAggregate = false;
    }

    function _zeroProof(uint256[8] calldata proof) private pure returns (bool) {
        for (uint256 i; i < 8; ++i) if (proof[i] != 0) return false;
        return true;
    }

}
