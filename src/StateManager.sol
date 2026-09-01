// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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

interface IZKVerifierProof {
    function verifyProof(uint256[8] calldata proof, uint256[2] calldata input) external view;
}

contract StateManager is OwnableUpgradeable {
    uint256 public constant VERSION = 2;
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
    // Legacy reserved storage slots kept for upgrade safety.
    mapping(bytes32 => bool) public knownDepositSubtreeRoots;
    mapping(bytes32 => bool) public knownWithdrawalSubtreeRoots;

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
    modifier onlyBridge() {
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        if (msg.sender != provider.getAddress(provider.BRIDGE_ID())) revert OnlyBridge();
        _;
    }

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
        address owner_,
        address addressesProvider_,
        uint8 l1ChainIndex_
    ) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        l1ChainIndex = l1ChainIndex_;
        knownDepositSubtreeRoots[bytes32(0)] = true;
        knownWithdrawalSubtreeRoots[bytes32(0)] = true;
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

    function finalize(
        bytes calldata proof,
        bytes32 depositTreeRoot,
        bytes32[2] calldata checkpointRoots,
        bytes32 withdrawalTreeRoot,
        uint8 provenChainIndex,
        uint64 newCheckpointId,
        bytes32[9] calldata depositMerkleProof,
        bytes32[9] calldata withdrawalMerkleProof
    ) external onlyProposer {
        IPsyAddressesProviderSM provider = IPsyAddressesProviderSM(addressesProvider);
        address zkVerifier = provider.getAddress(provider.ZK_VERIFIER_ID());
        if (zkVerifier == address(0)) revert VerifierNotSet();
        if (provenChainIndex != l1ChainIndex) revert InvalidProvenChainIndex();

        bool isFirstFinalize = lastFinalizedCheckpointId == 0;

        if (!isFirstFinalize) {
            if (checkpointRoots[0] != lastVerifiedCheckpointRoot) revert InvalidCheckpointContinuity();
        }

        require(newCheckpointId > lastFinalizedCheckpointId, "newCheckpointId must advance past lastFinalizedCheckpointId");
        uint64 numCheckpointsAggregated = newCheckpointId - lastFinalizedCheckpointId;

        _validateBridgeTreeProofs(
            depositTreeRoot,
            withdrawalTreeRoot,
            depositMerkleProof,
            withdrawalMerkleProof,
            isFirstFinalize
        );
        _verifyFinalizeProof(
            zkVerifier,
            proof,
            checkpointRoots,
            depositTreeRoot,
            withdrawalTreeRoot,
            newCheckpointId,
            numCheckpointsAggregated
        );

        knownDepositSubtreeRoots[depositMerkleProof[0]] = true;
        knownWithdrawalSubtreeRoots[withdrawalMerkleProof[0]] = true;
        lastVerifiedCheckpointRoot = checkpointRoots[1];
        lastVerifiedDepositTreeRoot = depositTreeRoot;
        lastVerifiedWithdrawalTreeRoot = withdrawalTreeRoot;
        withdrawalSubtreeRoot = withdrawalMerkleProof[0];
        lastFinalizedCheckpointId = newCheckpointId;

        emit Finalized(
            lastFinalizedCheckpointId,
            lastVerifiedCheckpointRoot,
            depositTreeRoot,
            withdrawalTreeRoot
        );
    }

    function _verifyTopTreeProof(bytes32 expectedRoot, bytes32[9] calldata proof, uint8 index) internal pure returns (bool) {
        if (expectedRoot == bytes32(0)) {
            bool allZero = true;
            for (uint8 i = 0; i < 9; ++i) {
                if (proof[i] != bytes32(0)) {
                    allZero = false;
                    break;
                }
            }
            if (allZero) return true;
        }

        bytes32 cur = proof[0];
        for (uint8 level = 0; level < 8; ++level) {
            bytes32 sibling = proof[level + 1];
            if (((index >> level) & 1) == 0) {
                cur = keccak256(abi.encodePacked(cur, sibling));
            } else {
                cur = keccak256(abi.encodePacked(sibling, cur));
            }
        }
        return cur == expectedRoot;
    }

    function _validateBridgeTreeProofs(
        bytes32 depositTreeRoot,
        bytes32 withdrawalTreeRoot,
        bytes32[9] calldata depositMerkleProof,
        bytes32[9] calldata withdrawalMerkleProof,
        bool isFirstFinalize
    ) internal view {
        if (!_verifyTopTreeProof(depositTreeRoot, depositMerkleProof, l1ChainIndex)) {
            revert InvalidDepositMerkleProof();
        }
        if (withdrawalTreeRoot == bytes32(0)) {
            // Keep empty-withdrawal bootstrap open until a non-zero withdrawal root has
            // been finalized. Catch-up finalizes with no withdrawals must not brick.
            if (!isFirstFinalize && lastVerifiedWithdrawalTreeRoot != bytes32(0)) {
                revert WithdrawalBootstrapExpired();
            }
            return;
        }
        if (!_verifyTopTreeProof(withdrawalTreeRoot, withdrawalMerkleProof, l1ChainIndex)) {
            revert InvalidWithdrawalMerkleProof();
        }
    }


    function _verifyFinalizeProof(
        address zkVerifier,
        bytes calldata proof,
        bytes32[2] calldata checkpointRoots,
        bytes32 depositTreeRoot,
        bytes32 withdrawalTreeRoot,
        uint64 newCheckpointId,
        uint64 numCheckpointsAggregated
    ) internal view {
        bytes32 msgHash = _computeGnarkPublicInputsHash(
            checkpointRoots,
            depositTreeRoot,
            withdrawalTreeRoot,
            newCheckpointId,
            numCheckpointsAggregated
        );
        uint256 pub0 = uint256(uint128(uint256(msgHash) >> 128));
        uint256 pub1 = uint256(uint128(uint256(msgHash)));
        if (!_verifyZkProof(zkVerifier, proof, pub0, pub1)) revert InvalidProof();
    }

    function _reverseBytes16(uint128 x) internal pure returns (uint128 y) {
        bytes16 b = bytes16(x);
        for (uint256 i = 0; i < 16; ++i) {
            y |= uint128(uint8(b[i])) << uint8(i * 8);
        }
    }

    function _pairSwapU32x8(bytes32 root) internal pure returns (bytes32) {
        uint256 x = uint256(root);
        return bytes32(
            (x & (uint256(0xffffffff) << 192)) << 32 |
            (x & (uint256(0xffffffff) << 224)) >> 32 |
            (x & (uint256(0xffffffff) << 128)) << 32 |
            (x & (uint256(0xffffffff) << 160)) >> 32 |
            (x & (uint256(0xffffffff) << 64)) << 32 |
            (x & (uint256(0xffffffff) << 96)) >> 32 |
            (x & uint256(0xffffffff)) << 32 |
            (x & (uint256(0xffffffff) << 32)) >> 32
        );
    }

    function _computeGnarkPublicInputsHash(
        bytes32[2] calldata checkpointRoots,
        bytes32 depositTreeRoot,
        bytes32 withdrawalTreeRoot,
        uint64 newCheckpointId,
        uint64 numCheckpointsAggregated
    ) internal pure returns (bytes32) {
        // BridgeWrap hashes the original BridgeAgg public inputs with mixed widths:
        // [0..4): old checkpoint root limbs as four uint64 values in PI order
        // [4..12): deposit tree root limbs as eight uint32 values
        // [12..20): withdrawal tree root limbs as eight uint32 values
        // [20..24): new checkpoint root limbs as four uint64 values in PI order
        // [24]: terminal checkpoint id (end_checkpoint_index / to_checkpoint) as uint64.
        // [25]: number of aggregated checkpoint proofs as uint64.
        // The L1 chain index is no longer a public input: a single finalize proof
        // can be reused across chains. The L1-side guard (provenChainIndex ==
        // l1ChainIndex) is enforced in finalize() via calldata.
        uint256 oldRoot = uint256(checkpointRoots[0]);
        uint256 newRoot = uint256(checkpointRoots[1]);
        return keccak256(
            abi.encodePacked(
                uint64(oldRoot),
                uint64(oldRoot >> 64),
                uint64(oldRoot >> 128),
                uint64(oldRoot >> 192),
                _pairSwapU32x8(depositTreeRoot),
                _pairSwapU32x8(withdrawalTreeRoot),
                uint64(newRoot),
                uint64(newRoot >> 64),
                uint64(newRoot >> 128),
                uint64(newRoot >> 192),
                newCheckpointId,
                numCheckpointsAggregated
            )
        );
    }

    function _verifyZkProof(address zkVerifier, bytes calldata proof, uint256 pub0, uint256 pub1) internal view returns (bool) {
        uint256[2] memory input = [pub0, pub1];

        // Only support the canonical gnark verifier ABI.
        if (proof.length == 32 * 8) {
            uint256[8] memory p = abi.decode(proof, (uint256[8]));
            try IZKVerifierProof(zkVerifier).verifyProof(p, input) {
                return true;
            } catch {}
        }

        return false;
    }
}
