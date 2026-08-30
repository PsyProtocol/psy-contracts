// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPsyAddressesProviderView {
    function ACL_MANAGER_ID() external view returns (bytes32);
    function STATE_MANAGER_ID() external view returns (bytes32);
    function ROUTER_ID() external view returns (bytes32);
    function ERC20_GATEWAY_ID() external view returns (bytes32);
    function ETH_GATEWAY_ID() external view returns (bytes32);
    function ZK_VERIFIER_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
}

interface IStateManager {
    function withdrawalSubtreeRoot() external view returns (bytes32);
    function knownWithdrawalSubtreeRoots(bytes32 root) external view returns (bool);
    function l1ChainIndex() external view returns (uint8);
    function BRIDGE_USER_ID() external view returns (uint64);
}

interface IRouterView {
    function tokenToGateway(address token) external view returns (address);
}

interface IETHGatewayView {
    function weth() external view returns (address);
}

interface IWETHWithdraw {
    function withdraw(uint256) external;
}

interface IPsyACLManagerBridge {
    function isBridgeAdmin(address account) external view returns (bool);
}

interface IGnarkGroth16Verifier {
    function verifyProof(uint256[8] calldata proof, uint256[2] calldata input) external view;
}

contract Bridge is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    uint256 public constant VERSION = 2;
    uint256 internal constant WITHDRAWAL_BATCH_CLAIM_PUBLIC_INPUTS_LEN = 18;
    uint256 internal constant WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS = 34;
    uint256 internal constant WITHDRAWAL_BATCH_CLAIM_SLOT_COUNT = 32;
    uint256 internal constant WITHDRAWAL_BATCH_CLAIM_SLOT_DATA_WORDS =
        WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS * WITHDRAWAL_BATCH_CLAIM_SLOT_COUNT;
    uint256 internal constant DEPOSIT_BATCH_APPEND_SLOT_WORDS = 41;
    uint256 internal constant DEPOSIT_BATCH_APPEND_SLOT_COUNT = 32;
    uint256 internal constant DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS =
        DEPOSIT_BATCH_APPEND_SLOT_WORDS * DEPOSIT_BATCH_APPEND_SLOT_COUNT;
    bytes32 internal constant EMPTY_DEPOSIT_ROOT =
        0xd65af5933a094e8329332a714327ba72b1e4dac93c0cde8ee479b9bb36c3fc43;
    bytes32 internal constant NON_MAPPING_STATE_HASH_DOMAIN = keccak256("PSY_BRIDGE_NON_MAPPING_STATE_V1");

    struct NonMappingState {
        bytes32 depositRoot;
        uint256 provedDepositCount;
        uint256 pendingDepositCount;
        bytes32[32] depositFrontier;
    }

    address public addressesProvider;
    mapping(bytes32 => bool) public claimedNullifiers;
    bytes32[32] internal _depositFrontier;
    bytes32 public depositRoot;
    uint256 public provedDepositCount;
    uint256 public pendingDepositCount;
    // L1-side keccak deposit leaves recorded for auditing/debugging. The L2 deposit tree still
    // appends the Poseidon leaf derived from the same opening fields.
    mapping(uint256 => bytes32) public depositLeafHashes;
    address public depositBatchVerifier;
    address public withdrawalClaimVerifier;

    event DepositRecorded(
        uint32 indexed index,
        bytes32 shieldAddress,
        address indexed token,
        bytes32 l2TokenContractId,
        uint256 amount,
        uint8 chainIndex,
        bytes32 noteCommitment,
        bytes32 leafHash
    );
    event WithdrawalClaimed(
        bytes32 indexed nonce,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );
    event DepositBatchAppended(
        uint32 indexed fromIndex,
        uint32 indexed toIndex,
        bytes32 newRoot,
        bytes32[32] oldFrontier,
        bytes32[] leafHashes
    );
    event DepositBatchVerifierUpdated(address indexed verifier);
    event WithdrawalClaimVerifierUpdated(address indexed verifier);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);
    event WETHUnwrappedAndRescued(address indexed weth, address indexed to, uint256 amount);
    event NonMappingStateReset(
        bytes32 indexed previousStateHash,
        bytes32 indexed newStateHash,
        bytes32 depositRoot,
        uint256 provedDepositCount,
        uint256 pendingDepositCount,
        bytes32[32] depositFrontier
    );

    error ZeroAddress();
    error ZeroAmount();
    error DirectDepositDisabled();
    error UnauthorizedGateway();
    error InvalidWithdrawalProof();
    error InvalidDepositBatchProof();
    error NullifierAlreadyClaimed();
    error TransferFailed();
    error InvalidPublicInputs();
    error WrongDestinationChain();
    error VerifierNotSet();
    error PendingDepositIndexTooLarge();
    error DepositFrontierMismatch();
    error DepositRootMismatch();
    error DepositBatchCommitMismatch();
    error InvalidBatchRange();
    error AddressHighBitsNonZero();
    error InvalidRealCount();

    error UnauthorizedBridgeAdmin();
    error UnexpectedCurrentState(bytes32 expectedStateHash, bytes32 actualStateHash);
    error InvalidRollbackTarget();
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(
        address owner_,
        address addressesProvider_,
        address depositBatchVerifier_,
        address withdrawalClaimVerifier_
    ) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        if (depositBatchVerifier_ == address(0)) revert ZeroAddress();
        if (withdrawalClaimVerifier_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        depositBatchVerifier = depositBatchVerifier_;
        withdrawalClaimVerifier = withdrawalClaimVerifier_;
        depositRoot = EMPTY_DEPOSIT_ROOT;
    }

    function getRevision() external pure virtual returns (uint256) {
        return VERSION;
    }

    function getDepositFrontier() external view returns (bytes32[32] memory) {
        return _depositFrontier;
    }

    function setDepositBatchVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        depositBatchVerifier = verifier;
        emit DepositBatchVerifierUpdated(verifier);
    }

    function setWithdrawalClaimVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        withdrawalClaimVerifier = verifier;
        emit WithdrawalClaimVerifierUpdated(verifier);
    }
    modifier onlyBridgeAdmin() {
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        address aclManager = provider.getAddress(provider.ACL_MANAGER_ID());
        if (!IPsyACLManagerBridge(aclManager).isBridgeAdmin(msg.sender)) {
            revert UnauthorizedBridgeAdmin();
        }
        _;
    }
    function resetNonMappingState(
        NonMappingState calldata expected,
        NonMappingState calldata target
    ) external onlyBridgeAdmin {
        bytes32[32] memory actualFrontier = _depositFrontier;
        bytes32 actualStateHash = _nonMappingStateHash(
            NonMappingState({
                depositRoot: depositRoot,
                provedDepositCount: provedDepositCount,
                pendingDepositCount: pendingDepositCount,
                depositFrontier: actualFrontier
            })
        );
        bytes32 targetStateHash = _nonMappingStateHash(target);
        if (actualStateHash == targetStateHash) return;

        bytes32 expectedStateHash = _nonMappingStateHash(expected);
        if (actualStateHash != expectedStateHash) {
            revert UnexpectedCurrentState(expectedStateHash, actualStateHash);
        }
        if (
            target.provedDepositCount > target.pendingDepositCount ||
            target.provedDepositCount > expected.provedDepositCount ||
            target.pendingDepositCount > expected.pendingDepositCount
        ) revert InvalidRollbackTarget();

        depositRoot = target.depositRoot;
        provedDepositCount = target.provedDepositCount;
        pendingDepositCount = target.pendingDepositCount;
        _depositFrontier = target.depositFrontier;

        emit NonMappingStateReset(
            actualStateHash,
            targetStateHash,
            target.depositRoot,
            target.provedDepositCount,
            target.pendingDepositCount,
            target.depositFrontier
        );
    }

    function _nonMappingStateHash(NonMappingState memory state_) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                NON_MAPPING_STATE_HASH_DOMAIN,
                state_.depositRoot,
                state_.provedDepositCount,
                state_.pendingDepositCount,
                state_.depositFrontier
            )
        );
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyBridgeAdmin {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyBridgeAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeRescued(to, amount);
    }

    function rescueWETHAsNative(address payable to, uint256 amount) external onlyBridgeAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        address wethAddr = _nativeWithdrawalAsset();
        IWETHWithdraw(wethAddr).withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit WETHUnwrappedAndRescued(wethAddr, to, amount);
    }

    function _stateManager() internal view returns (IStateManager) {
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        return IStateManager(provider.getAddress(provider.STATE_MANAGER_ID()));
    }

    function _nativeWithdrawalAsset() internal view returns (address) {
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        address ethGateway = provider.getAddress(provider.ETH_GATEWAY_ID());
        if (ethGateway == address(0)) revert ZeroAddress();
        return IETHGatewayView(ethGateway).weth();
    }

    function _isAuthorizedGateway(address token) internal view returns (bool) {
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        address ethGateway = provider.getAddress(provider.ETH_GATEWAY_ID());
        address defaultERC20Gateway = provider.getAddress(provider.ERC20_GATEWAY_ID());
        address routerAddr = provider.getAddress(provider.ROUTER_ID());

        if (token == address(0)) {
            return msg.sender == ethGateway;
        }

        address tokenGateway = IRouterView(routerAddr).tokenToGateway(token);
        if (tokenGateway != address(0)) {
            return msg.sender == tokenGateway;
        }
        return msg.sender == defaultERC20Gateway;
    }

    function _recordDepositLeaf(
        address token,
        bytes32 l2TokenContractId,
        uint256 amount,
        bytes32 shieldAddress,
        bytes32 noteCommitment
    )
        internal
        returns (uint32 index, bytes32 newRoot)
    {
        IStateManager sm = _stateManager();
        uint8 chainIndex = sm.l1ChainIndex();
        if (pendingDepositCount > type(uint32).max) revert PendingDepositIndexTooLarge();

        bytes32 tokenBytes32 = _addressToBytes32(token);
        bytes32 leafHash = keccak256(
            abi.encodePacked(
                shieldAddress,
                tokenBytes32,
                l2TokenContractId,
                amount,
                uint32(chainIndex),
                noteCommitment
            )
        );

        index = uint32(pendingDepositCount);
        depositLeafHashes[pendingDepositCount] = leafHash;
        pendingDepositCount++;
        newRoot = bytes32(0);

        emit DepositRecorded(
            index,
            shieldAddress,
            token,
            l2TokenContractId,
            amount,
            chainIndex,
            noteCommitment,
            leafHash
        );
    }

    function recordDeposit(address token, uint256 amount, bytes32 shieldAddress, bytes32 noteCommitment) external pure returns (uint32, bytes32) {
        token;
        amount;
        shieldAddress;
        noteCommitment;
        revert DirectDepositDisabled();
    }

    function recordDepositFromGateway(
        address token,
        bytes32 l2TokenContractId,
        uint256 amount,
        bytes32 shieldAddress,
        bytes32 noteCommitment
    )
        external
        returns (uint32 index, bytes32 newRoot)
    {
        if (!_isAuthorizedGateway(token)) revert UnauthorizedGateway();
        if (amount == 0) revert ZeroAmount();

        return _recordDepositLeaf(token, l2TokenContractId, amount, shieldAddress, noteCommitment);
    }

    function batchAppend(
        uint256[8] calldata proof,
        uint256[] calldata publicInputs,
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] calldata slotData
    ) external {
        if (publicInputs.length < 18) revert InvalidPublicInputs();
        if (publicInputs[16] > type(uint32).max || publicInputs[17] > type(uint32).max) revert InvalidPublicInputs();

        uint32 fromIndex = uint32(publicInputs[16]);
        uint32 toIndex = uint32(publicInputs[17]);
        if (toIndex < fromIndex) revert InvalidBatchRange();
        if (uint256(fromIndex) != provedDepositCount) revert InvalidBatchRange();
        uint256 n = uint256(toIndex) - uint256(fromIndex);
        if (uint256(toIndex) > pendingDepositCount) revert InvalidBatchRange();

        if (n == 0 || n > 32) revert InvalidBatchRange();
        uint256 oldFrontierOffset = 18 + 32 * 8;
        uint256 newFrontierOffset = oldFrontierOffset + 32 * 8;
        uint256 bridgeUserIdOffset = newFrontierOffset + 32 * 8;
        uint256 batchCommitOffset = bridgeUserIdOffset + 1;
        if (publicInputs.length < batchCommitOffset + 8) revert InvalidPublicInputs();
        bytes32[32] memory oldFrontier;
        bytes32[] memory leafHashes = new bytes32[](n);

        bytes32 oldRoot = _u32x8ToBytes32(publicInputs, 0);
        bytes32 currentDepositRoot =
            depositRoot == bytes32(0) && provedDepositCount == 0 ? EMPTY_DEPOSIT_ROOT : depositRoot;
        if (oldRoot != currentDepositRoot) revert DepositRootMismatch();

        for (uint256 i = 0; i < 32; ++i) {
            bytes32 frontierNode = _u32x8ToBytes32(publicInputs, oldFrontierOffset + i * 8);
            oldFrontier[i] = frontierNode;
            if (frontierNode != _depositFrontier[i]) {
                revert DepositFrontierMismatch();
            }
        }

        for (uint256 i = 0; i < n; ++i) {
            leafHashes[i] = _u32x8ToBytes32(publicInputs, 18 + i * 8);
        }

        bytes32 proofBatchCommit = _u32x8ToBytes32Concat(publicInputs, batchCommitOffset);
        bytes32 computedBatchCommit = _computeDepositBatchSlotDataCommit(slotData);
        for (uint256 i = 0; i < DEPOSIT_BATCH_APPEND_SLOT_COUNT; ++i) {
            uint256 slotOffset = i * DEPOSIT_BATCH_APPEND_SLOT_WORDS;
            bytes32 shieldAddress = _u32x8ToBytes32Concat(slotData, slotOffset);
            bytes32 tokenBytes32 = _u32x8ToBytes32Concat(slotData, slotOffset + 8);
            bytes32 l2TokenContractId = _u32x8ToBytes32Concat(slotData, slotOffset + 16);
            bytes32 amountBytes32 = _u32x8ToBytes32Concat(slotData, slotOffset + 24);
            uint32 chainIndex = uint32(slotData[slotOffset + 32]);
            bytes32 noteCommitment = _u32x8ToBytes32Concat(slotData, slotOffset + 33);

            if (i >= n) {
                if (
                    shieldAddress != bytes32(0) ||
                    tokenBytes32 != bytes32(0) ||
                    l2TokenContractId != bytes32(0) ||
                    amountBytes32 != bytes32(0) ||
                    chainIndex != 0 ||
                    noteCommitment != bytes32(0)
                ) revert InvalidPublicInputs();
                continue;
            }

            bytes32 expectedLeafHash = _computeDepositLeafHash(
                shieldAddress,
                tokenBytes32,
                l2TokenContractId,
                uint256(amountBytes32),
                chainIndex,
                noteCommitment
            );
            if (expectedLeafHash != depositLeafHashes[uint256(fromIndex) + i]) {
                revert DepositBatchCommitMismatch();
            }
        }
        if (proofBatchCommit != computedBatchCommit) {
            revert DepositBatchCommitMismatch();
        }

        if (depositBatchVerifier == address(0)) revert VerifierNotSet();
        bytes32 msgHash = _computeDepositBatchPublicInputsHash(publicInputs);
        uint256 pub0 = uint256(uint128(uint256(msgHash) >> 128));
        uint256 pub1 = uint256(uint128(uint256(msgHash)));
        uint256[2] memory pubs = [pub0, pub1];
        try IGnarkGroth16Verifier(depositBatchVerifier).verifyProof(proof, pubs) {} catch {
            revert InvalidDepositBatchProof();
        }

        depositRoot = _u32x8ToBytes32(publicInputs, 8);
        provedDepositCount = uint256(toIndex);
        for (uint256 i = 0; i < 32; ++i) {
            _depositFrontier[i] = _u32x8ToBytes32(publicInputs, newFrontierOffset + i * 8);
        }

        emit DepositBatchAppended(fromIndex, toIndex, depositRoot, oldFrontier, leafHashes);
    }

    function batchClaimWithdrawal(
        uint256[8] calldata proof,
        uint256[WITHDRAWAL_BATCH_CLAIM_PUBLIC_INPUTS_LEN] calldata publicInputs,
        uint256[WITHDRAWAL_BATCH_CLAIM_SLOT_DATA_WORDS] calldata slotData
    ) external {
        if (withdrawalClaimVerifier == address(0)) revert VerifierNotSet();

        bytes32 msgHash = _computeWithdrawalBatchClaimPublicInputsHash(publicInputs);
        uint256 pub0 = uint256(uint128(uint256(msgHash) >> 128));
        uint256 pub1 = uint256(uint128(uint256(msgHash)));
        uint256[2] memory pubs = [pub0, pub1];
        IGnarkGroth16Verifier(withdrawalClaimVerifier).verifyProof(proof, pubs);

        uint32 realCount = uint32(publicInputs[8]);
        uint32 bridgeUserId = uint32(publicInputs[9]);
        if (realCount == 0 || realCount > 32) revert InvalidRealCount();

        IStateManager sm = _stateManager();
        bytes32 proofRoot = _u32x8ToBytes32Concat(publicInputs, 0);
        bytes32 onChainRoot = sm.withdrawalSubtreeRoot();
        if (proofRoot != onChainRoot && !sm.knownWithdrawalSubtreeRoots(proofRoot)) {
            revert InvalidWithdrawalProof();
        }

        if (bridgeUserId != sm.BRIDGE_USER_ID()) revert InvalidPublicInputs();

        bytes32 proofBatchCommit = _u32x8ToBytes32Concat(publicInputs, 10);
        bytes32 computedBatchCommit = _computeWithdrawalBatchSlotDataCommit(slotData);

        for (uint256 i = 0; i < WITHDRAWAL_BATCH_CLAIM_SLOT_COUNT; ++i) {
            uint256 slotOffset = i * WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS;
            uint32 senderUserId = uint32(slotData[slotOffset]);
            bytes32 recipientBytes32 = _u32x8ToBytes32Concat(slotData, slotOffset + 1);
            bytes32 tokenBytes32 = _u32x8ToBytes32Concat(slotData, slotOffset + 9);
            bytes32 amountBytes32 = _u32x8ToBytes32Concat(slotData, slotOffset + 17);
            bytes32 nonce = _u32x8ToBytes32Concat(slotData, slotOffset + 25);
            uint32 destinationChainIndex = uint32(slotData[slotOffset + 33]);

            if (i >= realCount) {
                if (
                    senderUserId != 0 ||
                    recipientBytes32 != bytes32(0) ||
                    tokenBytes32 != bytes32(0) ||
                    amountBytes32 != bytes32(0) ||
                    nonce != bytes32(0) ||
                    destinationChainIndex != 0
                ) revert InvalidPublicInputs();
                continue;
            }

            if ((uint256(recipientBytes32) >> 160) != 0) revert AddressHighBitsNonZero();
            if ((uint256(tokenBytes32) >> 160) != 0) revert AddressHighBitsNonZero();
            address recipientAddr = address(uint160(uint256(recipientBytes32)));
            address tokenAddr = address(uint160(uint256(tokenBytes32)));
            uint256 amount = uint256(amountBytes32);

            if (destinationChainIndex != sm.l1ChainIndex()) revert WrongDestinationChain();
            if (recipientAddr == address(0)) revert ZeroAddress();
            if (amount == 0) revert ZeroAmount();

            if (claimedNullifiers[nonce]) revert NullifierAlreadyClaimed();
            claimedNullifiers[nonce] = true;

            if (tokenAddr == address(0)) {
                address wethAddr = _nativeWithdrawalAsset();
                IWETHWithdraw(wethAddr).withdraw(amount);
                (bool ok,) = payable(recipientAddr).call{value: amount}("");
                if (!ok) revert TransferFailed();
            } else {
                IERC20(tokenAddr).safeTransfer(recipientAddr, amount);
            }

            emit WithdrawalClaimed(nonce, recipientAddr, tokenAddr, amount);
        }

        if (computedBatchCommit != proofBatchCommit) revert InvalidWithdrawalProof();
    }

    function _addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _bytes32ToAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function _u32x8ToBytes32(uint256[44] calldata pi, uint256 offset) internal pure returns (bytes32 result) {
        for (uint256 i = 0; i < 8; i++) {
            if (pi[offset + i] > type(uint32).max) revert InvalidPublicInputs();
            result |= bytes32(pi[offset + i] << (i * 32));
        }
    }

    function _u32x8ToBytes32Concat(uint256[44] calldata pi, uint256 offset) internal pure returns (bytes32 result) {
        for (uint256 i = 0; i < 8; i++) {
            if (pi[offset + i] > type(uint32).max) revert InvalidPublicInputs();
            result |= bytes32(pi[offset + i] << (224 - i * 32));
        }
    }

    function _u32x8ToBytes32Concat(
        uint256[WITHDRAWAL_BATCH_CLAIM_PUBLIC_INPUTS_LEN] calldata pi,
        uint256 offset
    ) internal pure returns (bytes32 result) {
        for (uint256 i = 0; i < 8; i++) {
            if (pi[offset + i] > type(uint32).max) revert InvalidPublicInputs();
            result |= bytes32(pi[offset + i] << (224 - i * 32));
        }
    }

    function _u32x8ToBytes32Concat(
        uint256[WITHDRAWAL_BATCH_CLAIM_SLOT_DATA_WORDS] calldata pi,
        uint256 offset
    ) internal pure returns (bytes32 result) {
        for (uint256 i = 0; i < 8; i++) {
            if (pi[offset + i] > type(uint32).max) revert InvalidPublicInputs();
            result |= bytes32(pi[offset + i] << (224 - i * 32));
        }
    }

    function _u32x8ToBytes32Concat(
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] calldata pi,
        uint256 offset
    ) internal pure returns (bytes32 result) {
        for (uint256 i = 0; i < 8; i++) {
            if (pi[offset + i] > type(uint32).max) revert InvalidPublicInputs();
            result |= bytes32(pi[offset + i] << (224 - i * 32));
        }
    }

    function _u32x8ToBytes32(uint256[] calldata words, uint256 start) internal pure returns (bytes32 out) {
        if (words.length < start + 8) revert InvalidPublicInputs();
        for (uint256 i = 0; i < 8; ++i) {
            if (words[start + i] > type(uint32).max) revert InvalidPublicInputs();
            out |= bytes32(words[start + i] << (i * 32));
        }
    }

    function _u32x8ToBytes32Concat(uint256[] calldata words, uint256 start) internal pure returns (bytes32 out) {
        if (words.length < start + 8) revert InvalidPublicInputs();
        for (uint256 i = 0; i < 8; ++i) {
            if (words[start + i] > type(uint32).max) revert InvalidPublicInputs();
            out |= bytes32(words[start + i] << (224 - i * 32));
        }
    }

    function _computeWithdrawalBatchClaimPublicInputsHash(
        uint256[WITHDRAWAL_BATCH_CLAIM_PUBLIC_INPUTS_LEN] calldata pi
    ) internal pure returns (bytes32) {
        bytes memory buf = new bytes((WITHDRAWAL_BATCH_CLAIM_PUBLIC_INPUTS_LEN / 2) * 8);
        for (uint256 k = 0; k < WITHDRAWAL_BATCH_CLAIM_PUBLIC_INPUTS_LEN / 2; k++) {
            if (pi[2 * k] > type(uint32).max || pi[2 * k + 1] > type(uint32).max) revert InvalidPublicInputs();
            uint64 packed = (uint64(pi[2 * k]) << 32) | uint64(pi[2 * k + 1]);
            uint256 offset = k * 8;
            buf[offset] = bytes1(uint8(packed >> 56));
            buf[offset + 1] = bytes1(uint8(packed >> 48));
            buf[offset + 2] = bytes1(uint8(packed >> 40));
            buf[offset + 3] = bytes1(uint8(packed >> 32));
            buf[offset + 4] = bytes1(uint8(packed >> 24));
            buf[offset + 5] = bytes1(uint8(packed >> 16));
            buf[offset + 6] = bytes1(uint8(packed >> 8));
            buf[offset + 7] = bytes1(uint8(packed));
        }
        return keccak256(buf);
    }

    function _computeWithdrawalBatchSlotDataCommit(
        uint256[WITHDRAWAL_BATCH_CLAIM_SLOT_DATA_WORDS] calldata slotData
    ) internal pure returns (bytes32) {
        bytes memory buf = new bytes(WITHDRAWAL_BATCH_CLAIM_SLOT_DATA_WORDS * 4);
        for (uint256 k = 0; k < WITHDRAWAL_BATCH_CLAIM_SLOT_DATA_WORDS; k++) {
            uint256 word = slotData[k];
            if (word > type(uint32).max) revert InvalidPublicInputs();
            uint256 offset = k * 4;
            buf[offset] = bytes1(uint8(word >> 24));
            buf[offset + 1] = bytes1(uint8(word >> 16));
            buf[offset + 2] = bytes1(uint8(word >> 8));
            buf[offset + 3] = bytes1(uint8(word));
        }
        return keccak256(buf);
    }

    function _computeDepositBatchSlotDataCommit(
        uint256[DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS] calldata slotData
    ) internal pure returns (bytes32) {
        bytes memory buf = new bytes(DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS * 4);
        for (uint256 k = 0; k < DEPOSIT_BATCH_APPEND_SLOT_DATA_WORDS; ++k) {
            uint256 word = slotData[k];
            if (word > type(uint32).max) revert InvalidPublicInputs();
            uint256 offset = k * 4;
            buf[offset] = bytes1(uint8(word >> 24));
            buf[offset + 1] = bytes1(uint8(word >> 16));
            buf[offset + 2] = bytes1(uint8(word >> 8));
            buf[offset + 3] = bytes1(uint8(word));
        }
        return keccak256(buf);
    }

    function _computeDepositLeafHash(
        bytes32 shieldAddress,
        bytes32 tokenBytes32,
        bytes32 l2TokenContractId,
        uint256 amount,
        uint32 chainIndex,
        bytes32 noteCommitment
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                shieldAddress,
                tokenBytes32,
                l2TokenContractId,
                amount,
                chainIndex,
                noteCommitment
            )
        );
    }

    function _computeDepositBatchPublicInputsHash(uint256[] calldata pi) internal pure returns (bytes32) {
        if (pi.length == 0) revert InvalidPublicInputs();
        bytes memory buf = new bytes(pi.length * 4);
        for (uint256 k = 0; k < pi.length; ++k) {
            uint256 word = pi[k];
            if (word > type(uint32).max) revert InvalidPublicInputs();
            uint256 offset = k * 4;
            buf[offset] = bytes1(uint8(word >> 24));
            buf[offset + 1] = bytes1(uint8(word >> 16));
            buf[offset + 2] = bytes1(uint8(word >> 8));
            buf[offset + 3] = bytes1(uint8(word));
        }
        return keccak256(abi.encodePacked(keccak256(buf)));
    }

    function _u32x8ToUint256(uint256[] calldata words, uint256 start) internal pure returns (uint256 out) {
        if (words.length < start + 8) revert InvalidPublicInputs();
        for (uint256 i = 0; i < 8; ++i) {
            if (words[start + i] > type(uint32).max) revert InvalidPublicInputs();
            out |= words[start + i] << (i * 32);
        }
    }
}
