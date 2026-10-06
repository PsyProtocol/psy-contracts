// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BridgeOpening} from "./BridgeOpening.sol";
import {IAggregateVerifier, IFinalizeVerifier} from "./IAggregateVerifier.sol";
import {IAggregateBridge} from "./IAggregateBridge.sol";
import {IEthereumRewardPayer} from "./IEthereumRewardPayer.sol";

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
        uint256[8] calldata finalizeProof, uint256[] calldata checkpointPublicInputs,
        uint256[8] calldata depositProof, bytes calldata depositOpening,
        uint256[8] calldata withdrawalProof, bytes calldata withdrawalOpening,
        uint256[8] calldata rewardProof, bytes calldata rewardOpening
    ) external onlyProposer {
        if (_applyingAggregate) revert AggregateReentrancy();
        if (configHash == bytes32(0)) revert VerifierNotSet();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(_aggregateConfig);
        BridgeOpening.localChain(config, l1ChainIndex, aggregateBridge, address(this));
        BridgeOpening.DepositAggregateOpening memory a = BridgeOpening.readDepositAggregate(depositOpening, config);
        uint256 ordinal = BridgeOpening.chainOrdinal(config, l1ChainIndex);
        if (a.starts[ordinal].startCheckpointId != lastFinalizedCheckpointId || a.starts[ordinal].startCheckpointRoot != lastVerifiedCheckpointRoot) revert InvalidCheckpointContinuity();
        bool advance = _verifyFinalize(finalizeProof, checkpointPublicInputs, a);
        _verify(depositVerifier, depositProof, a.depositOpeningDigest);
        BridgeOpening.WithdrawalAggregateOpening memory w = BridgeOpening.readWithdrawalAggregate(withdrawalOpening, config);
        BridgeOpening.RewardAggregateOpening memory r = BridgeOpening.readRewardAggregate(rewardOpening, config);
        _verifyContext(a, w.context);
        _verifyContext(a, r.context);
        for (uint256 i; i < config.chains.length; ++i) {
            uint256 base = 26 + 9 * i;
            if (a.deposits[i].chainIndex != config.chains[i].chainIndex || _checkpointRoot(checkpointPublicInputs, base) != a.deposits[i].newRoot || checkpointPublicInputs[base + 4] > type(uint32).max || checkpointPublicInputs[base + 4] != a.deposits[i].newCount) revert InvalidDepositMerkleProof();
            if (_checkpointRoot(checkpointPublicInputs, base + 5) != w.withdrawalRoots[i]) revert InvalidWithdrawalMerkleProof();
        }
        _verifyAggregate(withdrawalVerifier, withdrawalProof, w.openingDigest, w.withdrawals.length);
        _verifyAggregate(rewardVerifier, rewardProof, r.openingDigest, r.rewards.length);
        IAggregateBridge bridge = IAggregateBridge(aggregateBridge);
        if (bridge.configHash() != configHash) revert InvalidDepositMerkleProof();
        _applyingAggregate = true;
        bridge.applyDepositAggregate(depositOpening);
        bridge.registerAggregateWithdrawals(w.withdrawals);
        if (l1ChainIndex == config.ethereumIndex && r.rewards.length != 0) {
            IEthereumRewardPayer payer = IEthereumRewardPayer(config.rewardPayer);
            if (payer.configHash() != configHash || payer.stateManager() != address(this) || payer.ethereumChainId() != block.chainid) revert InvalidProvenChainIndex();
            payer.payRewards(r.rewards);
        }
        if (advance) {
            lastFinalizedCheckpointId = a.endCheckpointId;
            lastVerifiedCheckpointRoot = a.endCheckpointRoot;
            lastVerifiedDepositTreeRoot = _slotRoot(checkpointPublicInputs, 4);
            lastVerifiedWithdrawalTreeRoot = _slotRoot(checkpointPublicInputs, 12);
            emit Finalized(a.endCheckpointId, a.endCheckpointRoot, lastVerifiedDepositTreeRoot, lastVerifiedWithdrawalTreeRoot);
        }
        if (depositSubtreeRoot != a.deposits[ordinal].newRoot) depositSubtreeRoot = a.deposits[ordinal].newRoot;
        if (depositCount != a.deposits[ordinal].newCount) depositCount = a.deposits[ordinal].newCount;
        _applyingAggregate = false;
        emit WithdrawalAggregateApplied(w.openingDigest, a.endCheckpointId, a.endCheckpointRoot);
        if (l1ChainIndex == config.ethereumIndex) emit RewardAggregateApplied(r.openingDigest, a.endCheckpointId, a.endCheckpointRoot);
    }

    function _verifyContext(BridgeOpening.DepositAggregateOpening memory a, BridgeOpening.DepositAggregateOpening memory b) private pure {
        if (a.configHash != b.configHash || a.windowId != b.windowId || a.endCheckpointId != b.endCheckpointId || a.endCheckpointRoot != b.endCheckpointRoot) revert InvalidCheckpointContinuity();
    }

    function _zeroProof(uint256[8] calldata proof) private pure returns (bool) {
        for (uint256 i; i < 8; ++i) if (proof[i] != 0) return false;
        return true;
    }

    function _verify(address verifier, uint256[8] calldata proof, bytes32 statement) private view {
        if (verifier.code.length == 0) revert VerifierNotSet();
        if (_zeroProof(proof)) revert InvalidProof();
        IAggregateVerifier(verifier).verifyProof(proof, BridgeOpening.proofInputs(statement));
    }

    function _verifyAggregate(address verifier, uint256[8] calldata proof, bytes32 statement, uint256 count) private view {
        if (count == 0) {
            if (!_zeroProof(proof)) revert InvalidProof();
        } else {
            _verify(verifier, proof, statement);
        }
    }

    function _checkpointRoot(uint256[] calldata inputs, uint256 start) private pure returns (bytes32 root) {
        uint256 packed;
        for (uint256 i; i < 4; ++i) {
            if (inputs[start + i] >= 18446744069414584321) revert InvalidProof();
            packed = (packed << 64) | inputs[start + i];
        }
        return bytes32(packed);
    }

    function _slotRoot(uint256[] calldata inputs, uint256 start) private pure returns (bytes32 root) {
        uint256 packed;
        for (uint256 i; i < 8; ++i) {
            if (inputs[start + i] > type(uint32).max) revert InvalidProof();
            packed = (packed << 32) | inputs[start + i];
        }
        return bytes32(packed);
    }

    function _verifyFinalize(uint256[8] calldata proof, uint256[] calldata inputs, BridgeOpening.DepositAggregateOpening memory a) private view returns (bool advance) {
        if (inputs.length != 26 + 9 * a.deposits.length) revert InvalidProof();
        if (inputs[24] > type(uint32).max || inputs[25] == 0 || inputs[25] > inputs[24] || inputs[24] != a.endCheckpointId || inputs[24] < lastFinalizedCheckpointId) revert InvalidCheckpointContinuity();
        bytes32 startRoot = _checkpointRoot(inputs, 0);
        if (_checkpointRoot(inputs, 20) != a.endCheckpointRoot) revert InvalidCheckpointContinuity();
        advance = inputs[24] > lastFinalizedCheckpointId;
        if (advance) {
            if (startRoot != lastVerifiedCheckpointRoot || inputs[25] != inputs[24] - lastFinalizedCheckpointId) revert InvalidCheckpointContinuity();
        } else if (a.endCheckpointRoot != lastVerifiedCheckpointRoot) {
            revert InvalidCheckpointContinuity();
        }
        bytes memory encoded = new bytes(144 + 72 * a.deposits.length);
        uint256 offset;
        for (uint256 i; i < inputs.length; ++i) {
            uint256 width = i >= 4 && i < 20 ? 4 : 8;
            uint256 value = inputs[width == 4 ? (i ^ 1) : i];
            if (width == 4 && value > type(uint32).max) revert InvalidProof();
            if (width == 8 && value > type(uint64).max) revert InvalidProof();
            for (uint256 j; j < width; ++j) encoded[offset + j] = bytes1(uint8(value >> (8 * (width - j - 1))));
            offset += width;
        }
        _verify(finalizeVerifier, proof, keccak256(encoded));
    }
}
