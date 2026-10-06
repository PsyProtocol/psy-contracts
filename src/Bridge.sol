// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {BridgeOpening} from "./BridgeOpening.sol";

interface IPsyAddressesProviderView {
    function ACL_MANAGER_ID() external view returns (bytes32);
    function STATE_MANAGER_ID() external view returns (bytes32);
    function ROUTER_ID() external view returns (bytes32);
    function ERC20_GATEWAY_ID() external view returns (bytes32);
    function ETH_GATEWAY_ID() external view returns (bytes32);
    function getAddress(bytes32 id) external view returns (address);
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
    function isGuardian(address account) external view returns (bool);
}


contract Bridge is Initializable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    uint256 public constant VERSION = 5;
    uint8 internal constant PAUSE_DEPOSITS = 1 << 0;
    uint8 internal constant PAUSE_WITHDRAWAL_REGISTRATION = 1 << 1;
    uint8 internal constant PAUSE_PENDING_CLAIMS = 1 << 2;
    uint8 internal constant ALL_PAUSE_FLAGS =
        PAUSE_DEPOSITS | PAUSE_WITHDRAWAL_REGISTRATION | PAUSE_PENDING_CLAIMS;
    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    bytes32 internal constant EMPTY_DEPOSIT_ROOT =
        0xe479b9bb36c3fc43b1e4dac93c0cde8e29332a714327ba72d65af5933a094e83;
    bytes32 internal constant FORCE_SET_STATE_HASH_DOMAIN = keccak256("PSY_BRIDGE_FORCE_SET_STATE_V1");

    struct BridgeContractState {
        bytes32 depositRoot;
        uint256 provedDepositCount;
        uint256 pendingDepositCount;
    }

    struct ImportedTokenFlowConfig {
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

    struct TokenFlowConfig {
        uint128 minDepositAmount;
        uint128 depositCap;
        uint128 smallWithdrawalMax;
        uint128 mediumWithdrawalMax;
        uint128 totalWithdrawalCap;
        uint32 smallWithdrawalDelay;
        uint32 mediumWithdrawalDelay;
        uint32 largeWithdrawalDelay;
        bool configured;
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
    // L1-side keccak deposit leaves recorded for auditing/debugging. The L2 deposit tree still
    // appends the Poseidon leaf derived from the same opening fields.
    mapping(uint256 => bytes32) public depositLeafHashes;
    address public depositBatchVerifier;
    address public withdrawalClaimVerifier;
    // Storage imported from the predecessor implementation is append-only after withdrawalClaimVerifier.
    mapping(address => ImportedTokenFlowConfig) private _importedTokenFlowConfigs;
    mapping(address => bytes32) private _reservedDepositBucketSlot;
    mapping(bytes32 => PendingWithdrawal) public pendingWithdrawals;
    mapping(address => uint8) private _tokenPauseFlags;
    uint8 private _globalPauseFlags;
    // Governed storage is append-only after the imported storage above.
    mapping(address => uint256) private _totalWithdrawalAmounts;
    address public withdrawalForceClaimExecutor;
    bytes32 public withdrawalTotalsTokenSetHash;
    mapping(address => TokenFlowConfig) private _tokenFlowConfigs;
    bytes private _aggregateConfig;
    bytes32 public configHash;
    address private _reservedAggregateVerifier;
    address public aggregateStateManager;
    uint8 public l1ChainIndex;

    event DepositAggregateApplied(bytes32 indexed depositOpeningDigest, uint32 endCount, bytes32 endRoot);
    error OnlyStateManager();

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
    event WithdrawalPendingCreated(
        bytes32 indexed nonce,
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint64 claimableAt
    );
    event WithdrawalForceClaimed(bytes32 indexed nonce, address indexed executor);
    event WithdrawalTotalInitialized(address indexed token, uint256 total);
    event TokenFlowConfigUpdated(address indexed token, bytes32 indexed oldHash, bytes32 indexed newHash);
    event TokenPauseFlagsUpdated(address indexed token, uint8 oldFlags, uint8 newFlags);
    event GlobalPauseFlagsUpdated(uint8 oldFlags, uint8 newFlags);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);
    event WETHUnwrappedAndRescued(address indexed weth, address indexed to, uint256 amount);
    event ForceSetState(
        bytes32 indexed previousStateHash,
        bytes32 indexed newStateHash,
        bytes32 depositRoot,
        uint256 provedDepositCount,
        uint256 pendingDepositCount
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
    error InvalidForceSetState();
    error UnauthorizedGuardian();
    error InvalidArrayLength();
    error DuplicateToken(address token);
    error InvalidFlowConfig(address token);
    error StaleConfigHash(bytes32 expected, bytes32 actual);
    error InvalidWithdrawalAmount(uint256 amount);
    error TokenNotConfigured(address token);
    error DepositsPaused(address token);
    error DepositBelowMinimum(address token, uint256 amount, uint256 minimum);
    error DepositCapExceeded(address token, uint256 custody, uint256 cap);
    error WithdrawalRegistrationPaused(address token);
    error ClaimableAtOverflow();
    error PendingWithdrawalNotFound(bytes32 nonce);
    error PendingWithdrawalNotClaimable(bytes32 nonce, uint64 claimableAt);
    error PendingClaimsPaused(address token);
    error InvalidPauseFlags(uint8 flags);
    error BridgeNotFullyPaused();
    error UnauthorizedFlowInitializer();
    error TotalWithdrawalAmountOverflow(address token, uint256 currentTotal, uint256 amount);
    error InvalidWithdrawalForceClaimExecutor(address executor);
    error UnauthorizedWithdrawalForceClaimExecutor(address caller);
    error WithdrawalTotalsTokenSetHashMismatch(bytes32 expected, bytes32 actual);
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    function initialize(
        address owner_, address addressesProvider_, bytes calldata networkConfig,
        uint8 chainIndex
    ) external initializer {
        __Ownable_init(owner_);
        if (addressesProvider_ == address(0)) revert ZeroAddress();
        addressesProvider = addressesProvider_;
        _initializeAggregation(networkConfig, chainIndex);
        depositRoot = EMPTY_DEPOSIT_ROOT;
    }


    function _initializeAggregation(bytes calldata networkConfig, uint8 chainIndex) internal {
        if (configHash != bytes32(0)) revert InvalidPublicInputs();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(networkConfig);
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        address manager = provider.getAddress(provider.STATE_MANAGER_ID());
        BridgeOpening.localChain(config, chainIndex, address(this), manager);
        _aggregateConfig = networkConfig;
        configHash = config.configHash;
        aggregateStateManager = manager;
        l1ChainIndex = chainIndex;
    }

    function getRevision() external pure virtual returns (uint256) {
        return VERSION;
    }


    function initializeFlowLimits(address[] calldata tokens, TokenFlowConfig[] calldata configs)
        external
        reinitializer(3)
        onlyFlowInitializer
    {
        if (tokens.length == 0 || tokens.length != configs.length) revert InvalidArrayLength();
        for (uint256 i = 0; i < tokens.length; ++i) {
            for (uint256 j = 0; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert DuplicateToken(tokens[i]);
            }
            _validateFlowConfig(tokens[i], configs[i]);
            _tokenFlowConfigs[tokens[i]] = configs[i];
            emit TokenFlowConfigUpdated(
                tokens[i], bytes32(0), keccak256(abi.encode(tokens[i], configs[i]))
            );
        }
    }
    function initializeWithdrawalTotals(
        address[] calldata configuredTokens,
        TokenFlowConfig[] calldata configs,
        uint256[] calldata historicalTotals,
        bytes32 expectedTokenSetHash,
        address forceClaimExecutor
    ) external reinitializer(4) onlyFlowInitializer {
        if (
            configuredTokens.length == 0 || configuredTokens.length != configs.length
                || configuredTokens.length != historicalTotals.length
        ) revert InvalidArrayLength();
        if (forceClaimExecutor == address(0) || forceClaimExecutor.code.length == 0) {
            revert InvalidWithdrawalForceClaimExecutor(forceClaimExecutor);
        }
        address[] memory sortedTokens = configuredTokens;
        for (uint256 i = 0; i < sortedTokens.length; ++i) {
            for (uint256 j = i; j > 0 && uint160(sortedTokens[j]) < uint160(sortedTokens[j - 1]); --j) {
                (sortedTokens[j - 1], sortedTokens[j]) = (sortedTokens[j], sortedTokens[j - 1]);
            }
        }
        for (uint256 i = 0; i < sortedTokens.length; ++i) {
            if (i != 0 && sortedTokens[i - 1] == sortedTokens[i]) revert DuplicateToken(sortedTokens[i]);
        }
        bytes32 actualTokenSetHash = keccak256(abi.encode(sortedTokens));
        if (expectedTokenSetHash != actualTokenSetHash) {
            revert WithdrawalTotalsTokenSetHashMismatch(expectedTokenSetHash, actualTokenSetHash);
        }
        for (uint256 i = 0; i < configuredTokens.length; ++i) {
            address token = configuredTokens[i];
            TokenFlowConfig storage currentConfig = _tokenFlowConfigs[token];
            if (!_importedTokenFlowConfigs[token].configured && !currentConfig.configured) revert TokenNotConfigured(token);
            _validateFlowConfig(token, configs[i]);
            bytes32 oldHash = currentConfig.configured ? keccak256(abi.encode(token, currentConfig)) : bytes32(0);
            _tokenFlowConfigs[token] = configs[i];
            _totalWithdrawalAmounts[token] = historicalTotals[i];
            emit TokenFlowConfigUpdated(token, oldHash, keccak256(abi.encode(token, configs[i])));
            emit WithdrawalTotalInitialized(token, historicalTotals[i]);
        }
        withdrawalTotalsTokenSetHash = actualTokenSetHash;
        withdrawalForceClaimExecutor = forceClaimExecutor;
    }

    function totalWithdrawalAmount(address token) external view returns (uint256) {
        return _totalWithdrawalAmounts[token];
    }

    function getTokenFlowConfig(address token) external view returns (TokenFlowConfig memory) {
        return _tokenFlowConfigs[token];
    }

    function getTokenFlowConfigHash(address token) public view returns (bytes32) {
        TokenFlowConfig storage config = _tokenFlowConfigs[token];
        if (!config.configured) return bytes32(0);
        return keccak256(abi.encode(token, config));
    }

    function setTokenFlowConfig(address token, TokenFlowConfig calldata next, bytes32 expectedConfigHash)
        external
        onlyBridgeAdmin
    {
        _validateFlowConfig(token, next);
        bytes32 oldHash = getTokenFlowConfigHash(token);
        if (expectedConfigHash != oldHash) revert StaleConfigHash(expectedConfigHash, oldHash);

        _tokenFlowConfigs[token] = next;

        emit TokenFlowConfigUpdated(token, oldHash, keccak256(abi.encode(token, next)));
    }

    function getPauseFlags(address token)
        external
        view
        returns (uint8 globalFlags, uint8 tokenFlags, uint8 effectiveFlags)
    {
        globalFlags = _globalPauseFlags;
        tokenFlags = _tokenPauseFlags[token];
        effectiveFlags = globalFlags | tokenFlags;
    }

    function guardianPauseToken(address token, uint8 flags) external onlyGuardian {
        _validatePauseFlags(flags);
        uint8 oldFlags = _tokenPauseFlags[token];
        uint8 newFlags = oldFlags | flags;
        _tokenPauseFlags[token] = newFlags;
        emit TokenPauseFlagsUpdated(token, oldFlags, newFlags);
    }

    function guardianPauseGlobal(uint8 flags) external onlyGuardian {
        _validatePauseFlags(flags);
        uint8 oldFlags = _globalPauseFlags;
        uint8 newFlags = oldFlags | flags;
        _globalPauseFlags = newFlags;
        emit GlobalPauseFlagsUpdated(oldFlags, newFlags);
    }

    function setTokenPauseFlags(address token, uint8 flags) external onlyBridgeAdmin {
        _validatePauseFlags(flags);
        uint8 oldFlags = _tokenPauseFlags[token];
        _tokenPauseFlags[token] = flags;
        emit TokenPauseFlagsUpdated(token, oldFlags, flags);
    }

    function setGlobalPauseFlags(uint8 flags) external onlyBridgeAdmin {
        _validatePauseFlags(flags);
        uint8 oldFlags = _globalPauseFlags;
        _globalPauseFlags = flags;
        emit GlobalPauseFlagsUpdated(oldFlags, flags);
    }

    modifier onlyBridgeAdmin() {
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        address aclManager = provider.getAddress(provider.ACL_MANAGER_ID());
        if (!IPsyACLManagerBridge(aclManager).isBridgeAdmin(msg.sender)) {
            revert UnauthorizedBridgeAdmin();
        }
        _;
    }
    function forceSetState(
        BridgeContractState calldata expected,
        BridgeContractState calldata target
    ) external onlyBridgeAdmin {
        bytes32 actualStateHash = _forceSetStateHash(
            BridgeContractState({
                depositRoot: depositRoot,
                provedDepositCount: provedDepositCount,
                pendingDepositCount: pendingDepositCount
            })
        );
        bytes32 targetStateHash = _forceSetStateHash(target);
        if (actualStateHash == targetStateHash) return;

        bytes32 expectedStateHash = _forceSetStateHash(expected);
        if (actualStateHash != expectedStateHash) {
            revert UnexpectedCurrentState(expectedStateHash, actualStateHash);
        }
        if (
            target.provedDepositCount > target.pendingDepositCount ||
            target.provedDepositCount > expected.provedDepositCount ||
            target.pendingDepositCount > expected.pendingDepositCount
        ) revert InvalidForceSetState();

        depositRoot = target.depositRoot;
        provedDepositCount = target.provedDepositCount;
        pendingDepositCount = target.pendingDepositCount;

        emit ForceSetState(
            actualStateHash,
            targetStateHash,
            target.depositRoot,
            target.provedDepositCount,
            target.pendingDepositCount
        );
    }

    function _forceSetStateHash(BridgeContractState memory state_) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FORCE_SET_STATE_HASH_DOMAIN,
                state_.depositRoot,
                state_.provedDepositCount,
                state_.pendingDepositCount
            )
        );
    }

    modifier onlyGuardian() {
        IPsyAddressesProviderView provider = IPsyAddressesProviderView(addressesProvider);
        address aclManager = provider.getAddress(provider.ACL_MANAGER_ID());
        if (!IPsyACLManagerBridge(aclManager).isGuardian(msg.sender)) {
            revert UnauthorizedGuardian();
        }
        _;
    }

    modifier onlyFlowInitializer() {
        if (msg.sender != owner() && msg.sender != ERC1967Utils.getAdmin()) {
            revert UnauthorizedFlowInitializer();
        }
        _;
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyBridgeAdmin {
        _requireFullyPaused();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function rescueNative(address payable to, uint256 amount) external onlyBridgeAdmin {
        _requireFullyPaused();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeRescued(to, amount);
    }

    function rescueWETHAsNative(address payable to, uint256 amount) external onlyBridgeAdmin {
        _requireFullyPaused();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        address wethAddr = _nativeWithdrawalAsset();
        IWETHWithdraw(wethAddr).withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit WETHUnwrappedAndRescued(wethAddr, to, amount);
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
        if (configHash == bytes32(0)) revert VerifierNotSet();
        uint8 chainIndex = l1ChainIndex;
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

        TokenFlowConfig storage config = _tokenFlowConfigs[token];
        if (!config.configured) revert TokenNotConfigured(token);
        if ((_effectivePauseFlags(token) & PAUSE_DEPOSITS) != 0) revert DepositsPaused(token);
        if (amount < config.minDepositAmount) {
            revert DepositBelowMinimum(token, amount, config.minDepositAmount);
        }

        uint256 custody = _custodyBalance(token);
        if (custody > config.depositCap) {
            revert DepositCapExceeded(token, custody, config.depositCap);
        }

        return _recordDepositLeaf(token, l2TokenContractId, amount, shieldAddress, noteCommitment);
    }

    function applyDepositAggregate(bytes calldata completeOpening) external {
        if (configHash == bytes32(0) || msg.sender != aggregateStateManager) revert OnlyStateManager();
        BridgeOpening.NetworkConfig memory config = BridgeOpening.readConfig(_aggregateConfig);
        BridgeOpening.localChain(config, l1ChainIndex, address(this), aggregateStateManager);
        BridgeOpening.DepositAggregateOpening memory a = BridgeOpening.readDepositAggregate(completeOpening, config);
        BridgeOpening.DepositTransition memory transition = a.deposits[BridgeOpening.chainOrdinal(config, l1ChainIndex)];
        if (transition.newCount > pendingDepositCount) revert InvalidBatchRange();
        for (uint256 i; i < a.depositLeaves.length; ++i) {
            BridgeOpening.DepositLeaf memory leaf = a.depositLeaves[i];
            if (leaf.chainIndex != l1ChainIndex) continue;
            bytes32 custodyHash = _computeDepositLeafHash(leaf.shieldAddress, _addressToBytes32(leaf.token), leaf.l2TokenContractId, leaf.amount, leaf.chainIndex, leaf.noteCommitment);
            if (custodyHash != depositLeafHashes[leaf.absoluteIndex]) revert DepositBatchCommitMismatch();
        }
        if (depositRoot == transition.newRoot && provedDepositCount == transition.newCount) {
            emit DepositAggregateApplied(a.depositOpeningDigest, transition.newCount, transition.newRoot);
            return;
        }
        if (depositRoot != transition.oldRoot || provedDepositCount != transition.oldCount) revert DepositRootMismatch();
        depositRoot = transition.newRoot;
        provedDepositCount = transition.newCount;
        emit DepositAggregateApplied(a.depositOpeningDigest, transition.newCount, transition.newRoot);
    }

    function registerAggregateWithdrawals(BridgeOpening.WithdrawalLeaf[] calldata withdrawals) external {
        if (configHash == bytes32(0) || msg.sender != aggregateStateManager) revert OnlyStateManager();
        for (uint256 i; i < withdrawals.length; ++i) {
            BridgeOpening.WithdrawalLeaf calldata leaf = withdrawals[i];
            if (leaf.chainIndex != l1ChainIndex) continue;
            if (leaf.recipient == address(0)) revert ZeroAddress();
            if (claimedNullifiers[leaf.nonce]) revert NullifierAlreadyClaimed();
            _registerPendingWithdrawal(leaf.nonce, leaf.token, leaf.recipient, leaf.amount);
            claimedNullifiers[leaf.nonce] = true;
        }
    }

    function claimPendingWithdrawal(bytes32 nonce) external {
        PendingWithdrawal memory pending = _loadPendingWithdrawal(nonce);
        if (block.timestamp < pending.claimableAt) {
            revert PendingWithdrawalNotClaimable(nonce, pending.claimableAt);
        }
        _settlePendingWithdrawal(nonce, pending);
    }

    function forceClaimWithdrawal(bytes32 nonce) external {
        if (msg.sender != withdrawalForceClaimExecutor) {
            revert UnauthorizedWithdrawalForceClaimExecutor(msg.sender);
        }
        PendingWithdrawal memory pending = _loadPendingWithdrawal(nonce);
        _settlePendingWithdrawal(nonce, pending);
        emit WithdrawalForceClaimed(nonce, msg.sender);
    }

    function _loadPendingWithdrawal(bytes32 nonce) internal view returns (PendingWithdrawal memory pending) {
        pending = pendingWithdrawals[nonce];
        if (pending.amount == 0) revert PendingWithdrawalNotFound(nonce);
        if ((_effectivePauseFlags(pending.token) & PAUSE_PENDING_CLAIMS) != 0) {
            revert PendingClaimsPaused(pending.token);
        }
    }

    function _settlePendingWithdrawal(bytes32 nonce, PendingWithdrawal memory pending) internal {
        delete pendingWithdrawals[nonce];
        if (pending.token == address(0)) {
            IWETHWithdraw(_nativeWithdrawalAsset()).withdraw(pending.amount);
            (bool ok,) = payable(pending.recipient).call{value: pending.amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(pending.token).safeTransfer(pending.recipient, pending.amount);
        }
        emit WithdrawalClaimed(nonce, pending.recipient, pending.token, pending.amount);
    }




    function _registerPendingWithdrawal(bytes32 nonce, address token, address recipient, uint256 amount) internal {
        TokenFlowConfig storage config = _tokenFlowConfigs[token];
        if (!config.configured) revert TokenNotConfigured(token);
        if ((_effectivePauseFlags(token) & PAUSE_WITHDRAWAL_REGISTRATION) != 0) {
            revert WithdrawalRegistrationPaused(token);
        }
        if (amount == 0 || amount >= GOLDILOCKS_PRIME) revert InvalidWithdrawalAmount(amount);

        uint256 currentTotal = _totalWithdrawalAmounts[token];
        if (amount > type(uint256).max - currentTotal) {
            revert TotalWithdrawalAmountOverflow(token, currentTotal, amount);
        }
        uint256 nextTotal = currentTotal + amount;

        uint32 delay;
        if (amount > config.mediumWithdrawalMax || nextTotal > config.totalWithdrawalCap) {
            delay = config.largeWithdrawalDelay;
        } else if (amount > config.smallWithdrawalMax) {
            delay = config.mediumWithdrawalDelay;
        } else {
            delay = config.smallWithdrawalDelay;
        }
        uint256 claimTime = block.timestamp + delay;
        if (claimTime > type(uint64).max) revert ClaimableAtOverflow();

        _totalWithdrawalAmounts[token] = nextTotal;
        pendingWithdrawals[nonce] = PendingWithdrawal(token, recipient, amount, uint64(claimTime));
        emit WithdrawalPendingCreated(nonce, token, recipient, amount, uint64(claimTime));
    }

    function _validateFlowConfig(address token, TokenFlowConfig calldata config) internal pure {
        if (
            !config.configured || config.minDepositAmount == 0 || config.depositCap < config.minDepositAmount
                || config.smallWithdrawalMax > config.mediumWithdrawalMax
                || config.smallWithdrawalDelay > config.mediumWithdrawalDelay
                || config.mediumWithdrawalDelay > config.largeWithdrawalDelay
        ) revert InvalidFlowConfig(token);
    }


    function _custodyBalance(address token) internal view returns (uint256) {
        address custodyToken = token == address(0) ? _nativeWithdrawalAsset() : token;
        return IERC20(custodyToken).balanceOf(address(this));
    }

    function _effectivePauseFlags(address token) internal view returns (uint8) {
        return _globalPauseFlags | _tokenPauseFlags[token];
    }

    function _validatePauseFlags(uint8 flags) internal pure {
        if ((flags & ~ALL_PAUSE_FLAGS) != 0) revert InvalidPauseFlags(flags);
    }

    function _requireFullyPaused() internal view {
        if (_globalPauseFlags != ALL_PAUSE_FLAGS) revert BridgeNotFullyPaused();
    }


    function _addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
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

}
