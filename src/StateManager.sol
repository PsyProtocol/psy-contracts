// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BridgeOpening} from "./BridgeOpening.sol";
import {IAggregateVerifier, IFinalizeVerifier} from "./IAggregateVerifier.sol";
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
    address private _reservedAggregateVerifier;
    address public aggregateBridge;
    uint32 public depositCount;
    bytes32 public depositSubtreeRoot;
    bool private _applyingAggregate;
    address public finalizeVerifier;
    address public depositVerifier;
    address public withdrawalVerifier;
    address public rewardVerifier;
    mapping(uint64 => AppliedWindow) private appliedWindowByEndCheckpointId;

    struct AppliedWindow {
        bytes32 windowId;
        bool isApplied;
    }

    event SettlementAggregateApplied(bytes32 indexed openingDigest, bytes32 indexed windowId, uint64 indexed endCheckpointId, bytes32 endCheckpointRoot, bytes32 batchRoot);
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
        bytes calldata networkConfig, address finalizeVerifier_, address depositVerifier_,
        address withdrawalVerifier_, address rewardVerifier_
    ) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        l1ChainIndex = l1ChainIndex_;
        BridgeOpening.ChainConfig memory chain = _initializeAggregation(networkConfig, finalizeVerifier_, depositVerifier_, withdrawalVerifier_, rewardVerifier_);
        lastFinalizedCheckpointId = chain.bootstrapId;
        lastVerifiedCheckpointRoot = chain.bootstrapRoot;
    }


    function _initializeAggregation(bytes calldata networkConfig, address finalizeVerifier_, address depositVerifier_, address withdrawalVerifier_, address rewardVerifier_) internal returns (BridgeOpening.ChainConfig memory chain) {
        if (configHash != bytes32(0) || finalizeVerifier_.code.length == 0 || depositVerifier_.code.length == 0 || withdrawalVerifier_.code.length == 0 || rewardVerifier_.code.length == 0) revert VerifierNotSet();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(networkConfig);
        bytes memory indices = new bytes(config.chains.length);
        for (uint256 i; i < indices.length; ++i) indices[i] = bytes1(config.chains[i].chainIndex);
        bytes32 chainListHash = keccak256(abi.encodePacked("PsyBridge/FinalizeChainList/1", uint16(indices.length), indices));
        if (IFinalizeVerifier(finalizeVerifier_).endpointChainListHash() != chainListHash) revert InvalidProvenChainIndex();
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        address bridge = provider.getAddress(provider.BRIDGE_ID());
        chain = BridgeOpening.localChain(config, l1ChainIndex, bridge, address(this));
        _aggregateConfig = networkConfig;
        configHash = config.configHash;
        finalizeVerifier = finalizeVerifier_;
        depositVerifier = depositVerifier_;
        withdrawalVerifier = withdrawalVerifier_;
        rewardVerifier = rewardVerifier_;
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

    function applyBridgeWindow(
        uint256[8] calldata depositProof, bytes calldata depositOpening,
        uint256[8] calldata windowFinalizationProof, bytes calldata windowFinalizationOpening
    ) external onlyProposer {
        if (_applyingAggregate) revert AggregateReentrancy();
        if (configHash == bytes32(0)) revert VerifierNotSet();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(_aggregateConfig);
        BridgeOpening.localChain(config, l1ChainIndex, aggregateBridge, address(this));
        BridgeOpening.DepositAggregateOpening memory a = BridgeOpening.readDepositAggregate(depositOpening, config);
        BridgeOpening.WindowFinalizationOpening memory windowFinalization = BridgeOpening.readWindowFinalizationOpening(windowFinalizationOpening, config, a.depositOpeningDigest);
        uint256 ordinal = BridgeOpening.chainOrdinal(config, l1ChainIndex);
        if (a.starts[ordinal].startCheckpointId != lastFinalizedCheckpointId || a.starts[ordinal].startCheckpointRoot != lastVerifiedCheckpointRoot) revert InvalidCheckpointContinuity();
        if (windowFinalization.configHash != a.configHash || windowFinalization.windowId != a.windowId || windowFinalization.endCheckpointId != a.endCheckpointId || windowFinalization.endCheckpointRoot != a.endCheckpointRoot) revert InvalidCheckpointContinuity();
        if (a.endCheckpointId < lastFinalizedCheckpointId) revert InvalidCheckpointContinuity();
        bool advance = a.endCheckpointId > lastFinalizedCheckpointId;
        if (!advance && a.endCheckpointRoot != lastVerifiedCheckpointRoot) revert InvalidCheckpointContinuity();
        for (uint256 i; i < config.chains.length; ++i) {
            _ensureFinalizationSlot(a.starts[i], windowFinalization.finalizations[i], a.endCheckpointId, a.endCheckpointRoot);
            if (windowFinalization.endpoints[i].depositRoot != a.deposits[i].newRoot || windowFinalization.endpoints[i].depositCount != a.deposits[i].newCount) revert InvalidDepositMerkleProof();
        }
        if (depositVerifier.code.length == 0 || finalizeVerifier.code.length == 0) revert VerifierNotSet();
        if (_zeroProof(depositProof) || _zeroProof(windowFinalizationProof)) revert InvalidProof();
        IAggregateVerifier(depositVerifier).verifyProof(depositProof, BridgeOpening.proofInputs(a.depositOpeningDigest));
        IAggregateVerifier(finalizeVerifier).verifyProof(windowFinalizationProof, BridgeOpening.proofInputs(windowFinalization.openingDigest));
        if (appliedWindowByEndCheckpointId[a.endCheckpointId].isApplied) revert InvalidCheckpointContinuity();
        IAggregateBridge bridge = IAggregateBridge(aggregateBridge);
        if (bridge.configHash() != configHash) revert InvalidDepositMerkleProof();
        _applyingAggregate = true;
        bridge.applyDepositAggregate(depositOpening);
        bridge.publishClaimHeader(BridgeOpening.withdrawalPublicationHeader(windowFinalization));
        if (advance) {
            lastFinalizedCheckpointId = a.endCheckpointId;
            lastVerifiedCheckpointRoot = a.endCheckpointRoot;
            lastVerifiedDepositTreeRoot = windowFinalization.globalDepositRoot;
            lastVerifiedWithdrawalTreeRoot = windowFinalization.globalWithdrawalRoot;
            emit Finalized(a.endCheckpointId, a.endCheckpointRoot, lastVerifiedDepositTreeRoot, lastVerifiedWithdrawalTreeRoot);
        }
        if (depositSubtreeRoot != a.deposits[ordinal].newRoot) depositSubtreeRoot = a.deposits[ordinal].newRoot;
        if (depositCount != a.deposits[ordinal].newCount) depositCount = a.deposits[ordinal].newCount;
        appliedWindowByEndCheckpointId[a.endCheckpointId] = AppliedWindow({windowId: windowFinalization.windowId, isApplied: true});
        _applyingAggregate = false;
        emit WithdrawalAggregateApplied(BridgeOpening.withdrawalFamilyDigest(windowFinalization), a.endCheckpointId, a.endCheckpointRoot);
        if (l1ChainIndex == config.ethereumIndex) emit RewardAggregateApplied(BridgeOpening.rewardFamilyDigest(windowFinalization), a.endCheckpointId, a.endCheckpointRoot);
        emit SettlementAggregateApplied(windowFinalization.openingDigest, windowFinalization.windowId, a.endCheckpointId, a.endCheckpointRoot, windowFinalization.batchRoot);
    }

    function _ensureFinalizationSlot(BridgeOpening.ChainStart memory start, BridgeOpening.FinalizationSlot memory slot, uint64 endCheckpointId, bytes32 endCheckpointRoot) private pure {
        if (start.startCheckpointId < endCheckpointId) {
            if (slot.startCheckpointRoot != start.startCheckpointRoot || uint256(slot.checkpointCount) != uint256(endCheckpointId) - uint256(start.startCheckpointId)) revert InvalidCheckpointContinuity();
            return;
        }
        if (start.startCheckpointRoot != endCheckpointRoot || slot.checkpointCount == 0) revert InvalidCheckpointContinuity();
    }

    function _zeroProof(uint256[8] calldata proof) private pure returns (bool) {
        for (uint256 i; i < 8; ++i) if (proof[i] != 0) return false;
        return true;
    }

}
