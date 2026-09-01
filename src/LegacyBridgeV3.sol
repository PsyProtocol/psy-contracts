// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract LegacyBridgeV3 is Initializable, OwnableUpgradeable {
    struct TokenFlowConfig {
        uint128 minDepositAmount;
        uint128 depositBucketCapacity;
        uint128 depositRefillPerSecond;
        uint128 custodyCap;
        uint128 smallWithdrawalMax;
        uint128 lifetimeWithdrawalThreshold;
        uint32 smallWithdrawalDelay;
        uint32 mediumWithdrawalDelay;
        uint32 thresholdExceededWithdrawalDelay;
        bool configured;
    }

    struct BucketState {
        uint128 available;
        uint64 lastUpdated;
    }

    struct PendingWithdrawal {
        address token;
        address recipient;
        uint256 amount;
        uint64 claimableAt;
    }

    address public addressesProvider;
    mapping(bytes32 => bool) public claimedNullifiers;
    bytes32[32] internal _depositFrontier;
    bytes32 public depositRoot;
    uint256 public provedDepositCount;
    uint256 public pendingDepositCount;
    mapping(uint256 => bytes32) public depositLeafHashes;
    address public depositBatchVerifier;
    address public withdrawalClaimVerifier;
    mapping(address => TokenFlowConfig) private _tokenFlowConfigs;
    mapping(address => BucketState) private _depositBuckets;
    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals;
    mapping(address => uint8) private _tokenPauseFlags;
    uint8 private _globalPauseFlags;

    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address provider, address depositVerifier, address withdrawalVerifier)
        external
        initializer
    {
        __Ownable_init(admin);
        addressesProvider = provider;
        depositBatchVerifier = depositVerifier;
        withdrawalClaimVerifier = withdrawalVerifier;
    }

    function initializeFlowLimits(address[] calldata tokens, TokenFlowConfig[] calldata configs)
        external
        reinitializer(3)
    {
        require(msg.sender == owner(), "owner");
        require(tokens.length == configs.length, "length");
        for (uint256 i = 0; i < tokens.length; ++i) _tokenFlowConfigs[tokens[i]] = configs[i];
    }
}
