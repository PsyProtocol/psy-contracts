// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IPsyAddressesProviderToken {
    function STATE_MANAGER_ID() external view returns (bytes32);
    function REWARD_CLAIM_VERIFIER_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
}

interface IStateManagerRewardRoot {
    function addressesProvider() external view returns (address);
    function lastFinalizedCheckpointId() external view returns (uint64);
    function rewardRootCheckpointId(bytes32 checkpointRoot) external view returns (uint64);
    function rewardRootsClean() external view returns (bool);
}

interface IZKVerifierProof {
    function verifyProof(uint256[8] calldata proof, uint256[2] calldata input) external view;
}

contract PsyToken is ERC20, Ownable {
    uint256 internal constant REWARD_CLAIM_MAX_CHECKPOINTS = 64;
    uint256 internal constant UINT128_MAX = type(uint128).max;
    bytes32 internal constant CLAIM_DOMAIN = keccak256("PsyReward/TokenCheckpointClaim/1");

    address public immutable addressesProvider;
    mapping(uint32 userId => mapping(uint32 checkpointId => bool)) public claimed;

    event RewardClaimed(
        uint32 indexed userId,
        address indexed recipient,
        bytes32 indexed checkpointRoot,
        uint32[] checkpointIds,
        uint256 totalAmount
    );

    error WrongChain();
    error ZeroAddress();
    error InvalidRewardClaim();
    error StateManagerNotSet();
    error VerifierNotSet();
    error ProviderMismatch();
    error UnrecognizedRewardRoot();
    error AlreadyClaimed();
    error InvalidProof();

    constructor(address initialHolder, uint256 initialSupply, address addressesProvider_)
        ERC20("Psy Token", "PSY")
        Ownable(initialHolder)
    {
        if (addressesProvider_.code.length == 0) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        _mint(initialHolder, initialSupply);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function claimReward(
        bytes calldata proof,
        bytes32 checkpointRoot,
        uint32 userId,
        address recipient,
        uint32[] calldata checkpointIds,
        uint256 totalAmount
    ) external {
        if (block.chainid != 1 && block.chainid != 31337 && block.chainid != 11155111) revert WrongChain();

        uint256 count = checkpointIds.length;
        if (recipient == address(0) || totalAmount == 0 || totalAmount > UINT128_MAX || count == 0
            || count > REWARD_CLAIM_MAX_CHECKPOINTS) {
            revert InvalidRewardClaim();
        }

        IPsyAddressesProviderToken provider = IPsyAddressesProviderToken(addressesProvider);
        address stateManager = provider.getAddress(provider.STATE_MANAGER_ID());
        if (stateManager.code.length == 0) revert StateManagerNotSet();
        address verifier = provider.getAddress(provider.REWARD_CLAIM_VERIFIER_ID());
        if (verifier.code.length == 0) revert VerifierNotSet();
        if (IStateManagerRewardRoot(stateManager).addressesProvider() != addressesProvider) revert ProviderMismatch();

        uint64 registeredCheckpointId = IStateManagerRewardRoot(stateManager).rewardRootCheckpointId(checkpointRoot);
        if (!IStateManagerRewardRoot(stateManager).rewardRootsClean() || registeredCheckpointId == 0
            || registeredCheckpointId > IStateManagerRewardRoot(stateManager).lastFinalizedCheckpointId()) {
            revert UnrecognizedRewardRoot();
        }

        uint32[REWARD_CLAIM_MAX_CHECKPOINTS] memory paddedIds;
        uint32 previousId;
        for (uint256 i; i < count; ++i) {
            uint32 checkpointId = checkpointIds[i];
            if (i != 0 && checkpointId <= previousId) revert InvalidRewardClaim();
            if (claimed[userId][checkpointId]) revert AlreadyClaimed();
            previousId = checkpointId;
            paddedIds[i] = checkpointId;
        }

        bytes32 commitment = keccak256(
            abi.encode(
                CLAIM_DOMAIN,
                address(this),
                stateManager,
                uint256(userId),
                recipient,
                checkpointRoot,
                uint256(count),
                uint256(totalAmount),
                paddedIds
            )
        );
        bytes32 messageHash = keccak256(abi.encode(commitment));
        if (proof.length != 256) revert InvalidProof();
        uint256[8] memory decodedProof = abi.decode(proof, (uint256[8]));
        uint256[2] memory input =
            [uint256(uint128(uint256(messageHash) >> 128)), uint256(uint128(uint256(messageHash)))];
        try IZKVerifierProof(verifier).verifyProof(decodedProof, input) {}
        catch {
            revert InvalidProof();
        }

        for (uint256 i; i < count; ++i) {
            claimed[userId][checkpointIds[i]] = true;
        }
        _mint(recipient, totalAmount);
        emit RewardClaimed(userId, recipient, checkpointRoot, checkpointIds, totalAmount);
    }
}
