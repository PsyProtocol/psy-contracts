// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library BridgeOpening {
    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    bytes32 internal constant CONFIG = keccak256("PsyBridge/TwoArtifact/1/Config");
    bytes32 internal constant DEPOSIT_AGGREGATE = keccak256("PsyBridge/TwoArtifact/1/A");
    bytes32 internal constant WITHDRAWAL = keccak256("PsyBridge/TwoArtifact/1/WithdrawalBatch");
    bytes32 internal constant REWARD = keccak256("PsyBridge/TwoArtifact/1/RewardBatch");
    bytes32 internal constant WINDOW = keccak256("PsyBridge/TwoArtifact/1/Window");
    bytes32 internal constant BATCH = keccak256("PsyBridge/TwoArtifact/1/Batch");
    bytes32 internal constant LEAF = keccak256("PsyBridge/TwoArtifact/1/Leaf");
    bytes32 internal constant EMPTY = keccak256("PsyBridge/TwoArtifact/1/Empty");
    bytes32 internal constant NODE = keccak256("PsyBridge/TwoArtifact/1/Node");
    bytes32 internal constant AGGREGATE_HEADER = keccak256("PsyBridge/TwoArtifact/1/AggregateHeader");
    bytes32 internal constant SOURCE_CHECKPOINT_REWARD_OPENING = keccak256("PsyBridge/SourceCheckpointReward/1/Opening");
    bytes32 internal constant RECORD = keccak256("PsyBridge/TwoArtifact/1/Record");
    bytes32 internal constant SOURCE_CHECKPOINT_REWARD_LEAF = keccak256("PsyBridge/SourceCheckpointReward/1/Leaf");
    uint256 internal constant CLAIM_TREE_MAX_CAPACITY = 131072;
    uint8 internal constant WITHDRAWAL_PUBLICATION_FAMILY = 2;
    uint8 internal constant REWARD_PUBLICATION_FAMILY = 3;
    bytes32 internal constant SETTLEMENT = keccak256("PsyBridge/TwoArtifact/2/B");
    bytes32 internal constant SETTLEMENT_EMPTY = keccak256("PsyBridge/TwoArtifact/2/Empty");
    bytes32 internal constant SETTLEMENT_BATCH = keccak256("PsyBridge/TwoArtifact/2/Batch");
    bytes32 internal constant SETTLEMENT_LEAF = keccak256("PsyBridge/TwoArtifact/2/Leaf");
    bytes32 internal constant SETTLEMENT_NODE = keccak256("PsyBridge/TwoArtifact/2/Node");
    uint256 internal constant MAX_SOURCE_CHAINS = 8;
    uint256 internal constant MAX_SETTLEMENT_LEAVES = 1024;

    struct ChainConfig { uint8 chainIndex; uint256 chainId; address bridge; address stateManager; uint64 bootstrapId; bytes32 bootstrapRoot; }
    struct NetworkConfig {
        bytes32 configHash;
        uint64 networkMagic;
        bytes32 circuitSetHash;
        ChainConfig[] chains;
        uint8 ethereumIndex;
        address rewardPayer;
        address rewardToken;
        uint256 rewardPerClaim;
        uint8 rewardTokenDecimals;
        uint64 rewardCutover;
        uint64 rewardEndExclusive;
        uint32 maxDeposits;
        uint32 maxWithdrawals;
        uint32 maxRewards;
    }
    struct ChainStart { uint8 chainIndex; uint64 startCheckpointId; bytes32 startCheckpointRoot; }
    struct DepositTransition { uint8 chainIndex; bytes32 oldRoot; bytes32 newRoot; uint32 oldCount; uint32 newCount; }
    struct DepositLeaf { uint8 chainIndex; uint32 absoluteIndex; bytes32 shieldAddress; address token; bytes32 l2TokenContractId; uint256 amount; bytes32 noteCommitment; }
    struct WithdrawalLeaf { uint8 chainIndex; uint32 senderUserId; address recipient; address token; uint256 amount; bytes32 nonce; }
    struct RewardLeaf { uint64 claimCheckpointId; uint32 userId; uint8 height; uint32 pathIndex; uint32 nullifierIndex; address recipient; }
    struct SourceCheckpointRewardLeaf { bytes32 economicDomain; uint64 sourceCheckpointId; uint32 userId; uint256 amount; address recipient; bool initialized; }
    struct DepositAggregateOpening {
        bytes32 configHash; bytes32 windowId; uint64 endCheckpointId; bytes32 endCheckpointRoot;
        ChainStart[] starts; DepositTransition[] deposits; DepositLeaf[] depositLeaves; bytes32 depositOpeningDigest;
    }
    struct WithdrawalAggregateOpening { DepositAggregateOpening context; bytes32[] withdrawalRoots; WithdrawalLeaf[] withdrawals; bytes32 openingDigest; }
    struct RewardAggregateOpening { DepositAggregateOpening context; RewardLeaf[] rewards; bytes32 openingDigest; }
    struct InclusionAggregateHeader {
        uint8 family;
        bytes32 configHash;
        bytes32 windowId;
        uint64 endCheckpointId;
        bytes32 endCheckpointRoot;
        uint32 aggregateCapacity;
        uint32 totalCount;
        uint32 segmentCount;
        uint32 segmentIndex;
        uint32 firstOrdinal;
        uint32 count;
        bytes32[] withdrawalRoots;
        bytes32 oldLedgerStateRoot;
        bytes32 newLedgerStateRoot;
        bytes32 openingDigest;
        bytes32 claimTreeRoot;
    }
    struct FinalizationSlot { bytes32 startCheckpointRoot; uint32 checkpointCount; }
    struct FinalizationEndpoint { bytes32 depositRoot; uint32 depositCount; bytes32 withdrawalRoot; }
    struct WindowFinalizationOpening {
        bytes32 configHash;
        bytes32 windowId;
        uint64 endCheckpointId;
        bytes32 endCheckpointRoot;
        bytes32 globalDepositRoot;
        bytes32 globalWithdrawalRoot;
        FinalizationSlot[] finalizations;
        FinalizationEndpoint[] endpoints;
        WithdrawalLeaf[] withdrawals;
        bytes32 oldRewardLedgerRoot;
        bytes32 newRewardLedgerRoot;
        bytes32 economicDomain;
        SourceCheckpointRewardLeaf[] rewards;
        bytes32 batchRoot;
        bytes32 openingDigest;
    }
    struct Cursor { uint256 offset; }
    error InvalidEncoding();
    error InvalidConfig();
    error InvalidOrdering();
    error InvalidCount();
    error InvalidCursor();
    error InvalidDepositState();
    error InvalidProof();

    function readWord(bytes memory body, Cursor memory cursor) private pure returns (uint256 value) {
        if (cursor.offset > body.length || body.length - cursor.offset < 32) revert InvalidEncoding();
        uint256 offset = cursor.offset;
        assembly ("memory-safe") { value := mload(add(add(body, 32), offset)) }
        cursor.offset = offset + 32;
    }
    function readUint(bytes memory body, Cursor memory cursor, uint256 bits) private pure returns (uint256 value) {
        value = readWord(body, cursor);
        if (value >> bits != 0) revert InvalidEncoding();
    }
    function readAddress(bytes memory body, Cursor memory cursor) private pure returns (address) {
        return address(uint160(readUint(body, cursor, 160)));
    }
    function readRoot(bytes memory body, Cursor memory cursor) private pure returns (bytes32 root) {
        uint256 packed;
        for (uint256 i; i < 4; ++i) {
            uint256 limb = readWord(body, cursor);
            if (limb >= GOLDILOCKS_PRIME) revert InvalidEncoding();
            packed = (packed << 64) | limb;
        }
        return bytes32(packed);
    }
    function readPacked(bytes memory body, uint256 offset, uint256 width) private pure returns (uint256 value) {
        if (offset > body.length || body.length - offset < width) revert InvalidEncoding();
        assembly ("memory-safe") {
            value := shr(mul(sub(32, width), 8), mload(add(add(body, 32), offset)))
        }
    }
    function readPacked32(bytes memory body, uint256 offset) private pure returns (bytes32 value) {
        if (offset > body.length || body.length - offset < 32) revert InvalidEncoding();
        assembly ("memory-safe") {
            value := mload(add(add(body, 32), offset))
        }
    }
    function readCanonicalHash4(bytes memory body, uint256 offset) private pure returns (bytes32 packed) {
        uint256 value;
        for (uint256 limb; limb < 4; ++limb) {
            uint256 felt = readPacked(body, offset + limb * 8, 8);
            if (felt >= GOLDILOCKS_PRIME) revert InvalidEncoding();
            value = (value << 64) | felt;
        }
        packed = bytes32(value);
    }
    function slice(bytes memory body, uint256 start, uint256 end) private pure returns (bytes memory out) {
        if (end > body.length || start > end) revert InvalidEncoding();
        out = new bytes(end - start);
        for (uint256 i; i < out.length; i += 32) {
            assembly ("memory-safe") { mstore(add(add(out, 32), i), mload(add(add(body, 32), add(start, i)))) }
        }
    }
    function readConfig(bytes memory body) internal pure returns (NetworkConfig memory config) {
        Cursor memory c;
        if (readUint(body, c, 32) != 1) revert InvalidConfig();
        config.networkMagic = uint64(readUint(body, c, 64));
        if (readUint(body, c, 32) != 524288) revert InvalidConfig();
        config.circuitSetHash = bytes32(readWord(body, c));
        uint256 n = readWord(body, c);
        if (n == 0 || n > 256) revert InvalidCount();
        config.chains = new ChainConfig[](n);
        for (uint256 i; i < n; ++i) {
            ChainConfig memory chain;
            chain.chainIndex = uint8(readUint(body, c, 8));
            chain.chainId = readWord(body, c);
            chain.bridge = readAddress(body, c);
            chain.stateManager = readAddress(body, c);
            chain.bootstrapId = uint64(readUint(body, c, 64));
            chain.bootstrapRoot = readRoot(body, c);
            if (chain.chainId == 0 || chain.bridge == address(0) || chain.stateManager == address(0)) revert InvalidConfig();
            if (i != 0 && config.chains[i - 1].chainIndex >= chain.chainIndex) revert InvalidOrdering();
            for (uint256 j; j < i; ++j) {
                if (config.chains[j].chainId == chain.chainId) revert InvalidConfig();
            }
            config.chains[i] = chain;
        }
        config.ethereumIndex = uint8(readUint(body, c, 8));
        config.rewardPayer = readAddress(body, c);
        config.rewardToken = readAddress(body, c);
        config.rewardPerClaim = readWord(body, c);
        config.rewardTokenDecimals = uint8(readUint(body, c, 8));
        config.rewardCutover = uint64(readUint(body, c, 64));
        config.rewardEndExclusive = uint64(readUint(body, c, 64));
        config.maxDeposits = uint32(readUint(body, c, 32));
        config.maxWithdrawals = uint32(readUint(body, c, 32));
        config.maxRewards = uint32(readUint(body, c, 32));
        if (c.offset != body.length) revert InvalidEncoding();
        if (config.rewardPayer == address(0) || config.rewardToken == address(0) || config.rewardPerClaim == 0 || config.rewardCutover >= config.rewardEndExclusive) revert InvalidConfig();
        if (config.maxDeposits > 1024 || config.maxWithdrawals > 1024 || config.maxRewards > 1024) revert InvalidCount();
        chainOrdinal(config, config.ethereumIndex);
        config.configHash = keccak256(bytes.concat(CONFIG, body));
    }
    function chainOrdinal(NetworkConfig memory config, uint8 index) internal pure returns (uint256) {
        for (uint256 i; i < config.chains.length; ++i) if (config.chains[i].chainIndex == index) return i;
        revert InvalidConfig();
    }
    function localChain(NetworkConfig memory config, uint8 index, address bridge, address stateManager) internal view returns (ChainConfig memory chain) {
        chain = config.chains[chainOrdinal(config, index)];
        if (chain.chainId != block.chainid || chain.bridge != bridge || chain.stateManager != stateManager) revert InvalidConfig();
    }
    function readDepositAggregate(bytes memory body, NetworkConfig memory config) internal pure returns (DepositAggregateOpening memory opening) {
        Cursor memory c;
        opening = readDepositAggregateFields(body, c, config);
        if (c.offset != body.length) revert InvalidEncoding();
    }
    function readDepositAggregateFields(bytes memory body, Cursor memory c, NetworkConfig memory config) private pure returns (DepositAggregateOpening memory a) {
        a.configHash = bytes32(readWord(body, c));
        a.windowId = bytes32(readWord(body, c));
        if (a.configHash != config.configHash) revert InvalidConfig();
        a.endCheckpointId = uint64(readUint(body, c, 64));
        a.endCheckpointRoot = readRoot(body, c);
        uint256 rowsStart = c.offset;
        uint256 n = readWord(body, c);
        if (n != config.chains.length) revert InvalidCount();
        a.starts = new ChainStart[](n);
        for (uint256 i; i < n; ++i) {
            ChainStart memory start;
            start.chainIndex = uint8(readUint(body, c, 8));
            start.startCheckpointId = uint64(readUint(body, c, 64));
            start.startCheckpointRoot = readRoot(body, c);
            if (start.chainIndex != config.chains[i].chainIndex) revert InvalidOrdering();
            if (start.startCheckpointId < config.chains[i].bootstrapId || start.startCheckpointId > a.endCheckpointId) revert InvalidCursor();
            if (start.startCheckpointId == config.chains[i].bootstrapId && start.startCheckpointRoot != config.chains[i].bootstrapRoot) revert InvalidCursor();
            if (start.startCheckpointId == a.endCheckpointId && start.startCheckpointRoot != a.endCheckpointRoot) revert InvalidCursor();
            a.starts[i] = start;
        }
        if (readWord(body, c) != n) revert InvalidCount();
        a.deposits = new DepositTransition[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            DepositTransition memory deposit;
            deposit.chainIndex = uint8(readUint(body, c, 8));
            deposit.oldRoot = readRoot(body, c);
            deposit.newRoot = readRoot(body, c);
            deposit.oldCount = uint32(readUint(body, c, 32));
            deposit.newCount = uint32(readUint(body, c, 32));
            if (deposit.chainIndex != config.chains[i].chainIndex) revert InvalidOrdering();
            if (deposit.newCount < deposit.oldCount) revert InvalidCount();
            if (deposit.newCount == deposit.oldCount && deposit.newRoot != deposit.oldRoot) revert InvalidDepositState();
            total += uint256(deposit.newCount) - deposit.oldCount;
            a.deposits[i] = deposit;
        }
        uint256 projectionEnd = c.offset;
        if (a.windowId != keccak256(bytes.concat(WINDOW, a.configHash, slice(body, 64, rowsStart), slice(body, rowsStart, projectionEnd)))) revert InvalidEncoding();
        uint256 count = readWord(body, c);
        if (count != total || count > config.maxDeposits) revert InvalidCount();
        uint256 recordsStart = c.offset;
        a.depositLeaves = new DepositLeaf[](count);
        uint256 row;
        uint256 consumed;
        for (uint256 i; i < count; ++i) {
            while (row < n && consumed == uint256(a.deposits[row].newCount) - a.deposits[row].oldCount) { ++row; consumed = 0; }
            if (row == n) revert InvalidCount();
            DepositLeaf memory leaf;
            leaf.chainIndex = uint8(readUint(body, c, 8));
            leaf.absoluteIndex = uint32(readUint(body, c, 32));
            leaf.shieldAddress = bytes32(readWord(body, c));
            leaf.token = readAddress(body, c);
            leaf.l2TokenContractId = bytes32(readWord(body, c));
            leaf.amount = readWord(body, c);
            leaf.noteCommitment = bytes32(readWord(body, c));
            if (leaf.chainIndex != a.deposits[row].chainIndex || leaf.absoluteIndex != uint256(a.deposits[row].oldCount) + consumed) revert InvalidOrdering();
            a.depositLeaves[i] = leaf;
            ++consumed;
        }
        bytes32 root = aggregateRoot(body, recordsStart, count, 7, 1, a);
        a.depositOpeningDigest = keccak256(bytes.concat(DEPOSIT_AGGREGATE, slice(body, 0, projectionEnd), abi.encode(count, (count + 31) / 32, root)));
    }
    function readAggregateContext(bytes memory body, Cursor memory c, NetworkConfig memory config) private pure returns (DepositAggregateOpening memory a) {
        a.configHash = bytes32(readWord(body, c));
        a.windowId = bytes32(readWord(body, c));
        if (a.configHash != config.configHash) revert InvalidConfig();
        a.endCheckpointId = uint64(readUint(body, c, 64));
        a.endCheckpointRoot = readRoot(body, c);
    }
    function readWithdrawalAggregate(bytes memory body, NetworkConfig memory config) internal pure returns (WithdrawalAggregateOpening memory b) {
        Cursor memory c;
        b.context = readAggregateContext(body, c, config);
        uint256 chains = readUint(body, c, 16);
        if (chains == 0 || chains > 256 || chains != config.chains.length) revert InvalidCount();
        b.withdrawalRoots = new bytes32[](chains);
        for (uint256 i; i < chains; ++i) b.withdrawalRoots[i] = readRoot(body, c);
        uint256 count = readUint(body, c, 32);
        if (count > config.maxWithdrawals || body.length != 288 + chains * 128 + count * 192) revert InvalidCount();
        b.withdrawals = new WithdrawalLeaf[](count);
        uint256 chain;
        for (uint256 i; i < count; ++i) {
            WithdrawalLeaf memory leaf;
            leaf.chainIndex = uint8(readUint(body, c, 8));
            leaf.senderUserId = uint32(readUint(body, c, 32));
            leaf.recipient = readAddress(body, c);
            leaf.token = readAddress(body, c);
            leaf.amount = readWord(body, c);
            leaf.nonce = bytes32(readWord(body, c));
            while (chain < config.chains.length && config.chains[chain].chainIndex < leaf.chainIndex) ++chain;
            if (chain == config.chains.length || config.chains[chain].chainIndex != leaf.chainIndex) revert InvalidOrdering();
            if (leaf.recipient == address(0) || leaf.amount == 0 || leaf.amount >= GOLDILOCKS_PRIME) revert InvalidEncoding();
            if (i != 0) {
                WithdrawalLeaf memory previous = b.withdrawals[i - 1];
                if (previous.chainIndex > leaf.chainIndex || (previous.chainIndex == leaf.chainIndex && previous.nonce >= leaf.nonce)) revert InvalidOrdering();
            }
            b.withdrawals[i] = leaf;
        }
        b.openingDigest = keccak256(abi.encodePacked(WITHDRAWAL, body));
    }
    function readRewardAggregate(bytes memory body, NetworkConfig memory config) internal pure returns (RewardAggregateOpening memory b) {
        Cursor memory c;
        b.context = readAggregateContext(body, c, config);
        uint256 count = readUint(body, c, 32);
        if (count > config.maxRewards || body.length != 256 + count * 192) revert InvalidCount();
        b.rewards = new RewardLeaf[](count);
        for (uint256 i; i < count; ++i) {
            RewardLeaf memory leaf;
            leaf.claimCheckpointId = uint64(readUint(body, c, 64));
            leaf.userId = uint32(readUint(body, c, 32));
            leaf.height = uint8(readUint(body, c, 8));
            leaf.pathIndex = uint32(readUint(body, c, 32));
            leaf.nullifierIndex = uint32(readUint(body, c, 32));
            leaf.recipient = readAddress(body, c);
            if (leaf.recipient == address(0) || leaf.height < 2 || leaf.height > 21) revert InvalidEncoding();
            if (leaf.pathIndex >= uint256(1) << (leaf.height - 2) || leaf.nullifierIndex != (uint256(1) << leaf.height) - 1 + leaf.pathIndex) revert InvalidEncoding();
            if (leaf.claimCheckpointId < config.rewardCutover || leaf.claimCheckpointId >= config.rewardEndExclusive || leaf.claimCheckpointId > b.context.endCheckpointId) revert InvalidCursor();
            if (i != 0) {
                RewardLeaf memory previous = b.rewards[i - 1];
                if (previous.claimCheckpointId > leaf.claimCheckpointId || (previous.claimCheckpointId == leaf.claimCheckpointId && previous.nullifierIndex >= leaf.nullifierIndex)) revert InvalidOrdering();
            }
            b.rewards[i] = leaf;
        }
        if (c.offset != body.length) revert InvalidEncoding();
        b.openingDigest = keccak256(abi.encodePacked(REWARD, body));
    }
    function aggregateRoot(bytes memory body, uint256 start, uint256 count, uint256 recordWords, uint256 family, DepositAggregateOpening memory a) private pure returns (bytes32) {
        uint256 chunks = (count + 31) / 32;
        uint256 width = 1;
        while (width < chunks) width <<= 1;
        bytes32[] memory nodes = new bytes32[](width);
        bytes memory context = abi.encode(BATCH, a.configHash, a.endCheckpointId, uint64(uint256(a.endCheckpointRoot) >> 192), uint64(uint256(a.endCheckpointRoot) >> 128), uint64(uint256(a.endCheckpointRoot) >> 64), uint64(uint256(a.endCheckpointRoot)));
        for (uint256 j; j < width; ++j) {
            if (j >= chunks) { nodes[j] = keccak256(abi.encode(EMPTY, family, j)); continue; }
            uint256 first = j * 32;
            uint256 real = count - first;
            if (real > 32) real = 32;
            bytes32 commitment = keccak256(bytes.concat(context, abi.encode(family, j, first, real), slice(body, start + first * recordWords * 32, start + (first + real) * recordWords * 32)));
            nodes[j] = keccak256(abi.encode(LEAF, family, j, commitment));
        }
        uint256 level;
        while (width > 1) {
            ++level;
            for (uint256 j; j < width / 2; ++j) nodes[j] = keccak256(abi.encode(NODE, level, nodes[2 * j], nodes[2 * j + 1]));
            width /= 2;
        }
        return nodes[0];
    }
    function proofInputs(bytes32 digest) internal pure returns (uint256[2] memory) {
        return [uint256(uint128(uint256(digest) >> 128)), uint256(uint128(uint256(digest)))];
    }
    function readInclusionAggregateHeader(bytes memory body) internal pure returns (InclusionAggregateHeader memory header) {
        uint256 offset;
        header.family = uint8(readPacked(body, offset, 1));
        offset = 1;
        header.configHash = readPacked32(body, offset);
        offset += 32;
        header.windowId = readPacked32(body, offset);
        offset += 32;
        header.endCheckpointId = uint64(readPacked(body, offset, 8));
        offset += 8;
        header.endCheckpointRoot = readCanonicalHash4(body, offset);
        offset += 32;
        header.aggregateCapacity = uint32(readPacked(body, offset, 4));
        offset += 4;
        header.totalCount = uint32(readPacked(body, offset, 4));
        offset += 4;
        header.segmentCount = uint32(readPacked(body, offset, 4));
        offset += 4;
        header.segmentIndex = uint32(readPacked(body, offset, 4));
        offset += 4;
        header.firstOrdinal = uint32(readPacked(body, offset, 4));
        offset += 4;
        header.count = uint32(readPacked(body, offset, 4));
        offset += 4;
        if (header.family == WITHDRAWAL_PUBLICATION_FAMILY) {
            if (body.length < offset + 64) revert InvalidEncoding();
            uint256 rootBytes = body.length - offset - 64;
            if (rootBytes % 32 != 0) revert InvalidCount();
            uint256 chains = rootBytes / 32;
            if (chains == 0 || chains > 256) revert InvalidCount();
            header.withdrawalRoots = new bytes32[](chains);
            for (uint256 i; i < chains; ++i) {
                header.withdrawalRoots[i] = readCanonicalHash4(body, offset);
                offset += 32;
            }
        } else if (header.family == REWARD_PUBLICATION_FAMILY) {
            header.oldLedgerStateRoot = readCanonicalHash4(body, offset);
            offset += 32;
            header.newLedgerStateRoot = readCanonicalHash4(body, offset);
            offset += 32;
        } else {
            revert InvalidConfig();
        }
        header.openingDigest = readPacked32(body, offset);
        offset += 32;
        header.claimTreeRoot = readPacked32(body, offset);
        offset += 32;
        if (offset != body.length) revert InvalidEncoding();
        validateInclusionHeader(header);
    }
    function inclusionHeaderDigest(bytes memory headerBytes) internal pure returns (bytes32) {
        readInclusionAggregateHeader(headerBytes);
        return keccak256(abi.encodePacked(AGGREGATE_HEADER, headerBytes));
    }
    function inclusionProofInputs(bytes memory headerBytes) internal pure returns (uint256[6] memory inputs) {
        InclusionAggregateHeader memory header = readInclusionAggregateHeader(headerBytes);
        uint256[2] memory opening = proofInputs(header.openingDigest);
        uint256[2] memory claim = proofInputs(header.claimTreeRoot);
        uint256[2] memory digest = proofInputs(keccak256(abi.encodePacked(AGGREGATE_HEADER, headerBytes)));
        inputs[0] = opening[0];
        inputs[1] = opening[1];
        inputs[2] = claim[0];
        inputs[3] = claim[1];
        inputs[4] = digest[0];
        inputs[5] = digest[1];
    }
    function verifyClaimPath(InclusionAggregateHeader memory header, uint32 localOrdinal, bytes32 leafCommit, bytes32[] memory siblings) internal pure returns (bytes32) {
        uint256 depth = claimDepth(header.aggregateCapacity);
        if (siblings.length != depth || localOrdinal >= header.count || header.count > header.aggregateCapacity) revert InvalidCount();
        bytes32 state = keccak256(abi.encodePacked(LEAF, bytes32(uint256(12)), bytes32(uint256(header.count)), bytes32(uint256(localOrdinal)), leafCommit));
        for (uint256 level; level < depth; ++level) {
            bytes32 sibling = siblings[level];
            bytes32 left = (uint256(localOrdinal) & (1 << level)) == 0 ? state : sibling;
            bytes32 right = (uint256(localOrdinal) & (1 << level)) == 0 ? sibling : state;
            state = keccak256(abi.encodePacked(NODE, bytes32(uint256(12)), bytes32(level + 1), left, right));
        }
        if (state != header.claimTreeRoot) revert InvalidProof();
        return leafCommit;
    }
    function validateInclusionHeader(InclusionAggregateHeader memory header) private pure {
        uint32 capacity = header.aggregateCapacity;
        if (capacity != 1024 && capacity != 2048 && capacity != 4096 && capacity != 8192) revert InvalidCount();
        uint32 total = header.totalCount;
        uint32 segments = total == 0 ? 0 : uint32((uint256(total) + capacity - 1) / capacity);
        if (header.segmentCount != segments) revert InvalidCount();
        if (total == 0) {
            if (header.segmentIndex != 0 || header.firstOrdinal != 0 || header.count != 0 || header.openingDigest != emptyOpeningDigest(header) || header.claimTreeRoot != emptyClaimTreeRoot(capacity)) revert InvalidCount();
        } else {
            if (header.segmentIndex >= segments) revert InvalidCount();
            uint256 first = uint256(header.segmentIndex) * capacity;
            if (first > type(uint32).max || header.firstOrdinal != first) revert InvalidCount();
            uint256 remaining = uint256(total) - first;
            uint256 expected = remaining < capacity ? remaining : uint256(capacity);
            if (header.count == 0 || header.count != expected) revert InvalidCount();
        }
        if (header.family == WITHDRAWAL_PUBLICATION_FAMILY) {
            if (header.withdrawalRoots.length == 0 || header.withdrawalRoots.length > 256 || header.oldLedgerStateRoot != bytes32(0) || header.newLedgerStateRoot != bytes32(0)) revert InvalidCount();
        } else if (header.totalCount == 0 && header.oldLedgerStateRoot != header.newLedgerStateRoot) {
            revert InvalidCursor();
        }
    }
    function claimDepth(uint256 capacity) private pure returns (uint256 depth) {
        if (capacity == 0 || capacity > CLAIM_TREE_MAX_CAPACITY || (capacity & (capacity - 1)) != 0) revert InvalidCount();
        while (capacity > 1) {
            capacity >>= 1;
            ++depth;
        }
    }
    function readWithdrawalLeaf(bytes memory body) internal pure returns (WithdrawalLeaf memory leaf) {
        if (body.length != 192) revert InvalidEncoding();
        Cursor memory cursor;
        leaf.chainIndex = uint8(readUint(body, cursor, 8));
        leaf.senderUserId = uint32(readUint(body, cursor, 32));
        leaf.recipient = readAddress(body, cursor);
        leaf.token = readAddress(body, cursor);
        leaf.amount = readWord(body, cursor);
        leaf.nonce = bytes32(readWord(body, cursor));
        if (cursor.offset != 192) revert InvalidEncoding();
        if (leaf.recipient == address(0) || leaf.amount == 0 || leaf.amount >= GOLDILOCKS_PRIME) revert InvalidEncoding();
    }
    function withdrawalLeafCommit(bytes memory body) internal pure returns (bytes32) {
        readWithdrawalLeaf(body);
        return keccak256(abi.encodePacked(RECORD, bytes32(uint256(2)), body));
    }
    function readSourceCheckpointRewardLeaf(bytes memory body) internal pure returns (SourceCheckpointRewardLeaf memory leaf) {
        if (body.length != 192) revert InvalidEncoding();
        Cursor memory cursor;
        leaf.economicDomain = bytes32(readWord(body, cursor));
        leaf.sourceCheckpointId = uint64(readUint(body, cursor, 64));
        leaf.userId = uint32(readUint(body, cursor, 32));
        leaf.amount = readWord(body, cursor);
        leaf.recipient = readAddress(body, cursor);
        uint256 flag = readUint(body, cursor, 64);
        if (flag > 1) revert InvalidEncoding();
        leaf.initialized = flag == 1;
        if (cursor.offset != 192) revert InvalidEncoding();
        if (!leaf.initialized && leaf.recipient != address(0)) revert InvalidEncoding();
    }
    function sourceCheckpointRewardLeafCommit(bytes memory body) internal pure returns (bytes32) {
        readSourceCheckpointRewardLeaf(body);
        return keccak256(abi.encodePacked(SOURCE_CHECKPOINT_REWARD_LEAF, body));
    }

    function readWindowFinalizationOpening(bytes memory body, NetworkConfig memory config, bytes32 depositOpeningDigest) internal pure returns (WindowFinalizationOpening memory opening) {
        Cursor memory cursor;
        opening.configHash = bytes32(readWord(body, cursor));
        if (opening.configHash != config.configHash) revert InvalidConfig();
        opening.windowId = bytes32(readWord(body, cursor));
        opening.endCheckpointId = uint64(readUint(body, cursor, 64));
        opening.endCheckpointRoot = readRoot(body, cursor);
        opening.globalDepositRoot = _readU32x8(body, cursor);
        opening.globalWithdrawalRoot = _readU32x8(body, cursor);
        opening.finalizations = _readFinalizations(body, cursor, config.chains.length);
        opening.endpoints = _readEndpoints(body, cursor, opening.finalizations.length);
        opening.withdrawals = _readWindowFinalizationWithdrawals(body, cursor, config);
        opening.oldRewardLedgerRoot = readRoot(body, cursor);
        opening.newRewardLedgerRoot = readRoot(body, cursor);
        opening.economicDomain = bytes32(readWord(body, cursor));
        opening.rewards = _readWindowFinalizationRewards(body, cursor, config, opening.economicDomain, opening.oldRewardLedgerRoot, opening.newRewardLedgerRoot);
        if (cursor.offset != body.length) revert InvalidEncoding();
        opening.batchRoot = _batchRoot(opening);
        opening.openingDigest = windowFinalizationOpeningDigest(opening, depositOpeningDigest);
    }

    function _readU32x8(bytes memory body, Cursor memory cursor) private pure returns (bytes32 packed) {
        uint256 value;
        for (uint256 i; i < 8; ++i) value = (value << 32) | readUint(body, cursor, 32);
        return bytes32(value);
    }

    function _readFinalizations(bytes memory body, Cursor memory cursor, uint256 chainCount) private pure returns (FinalizationSlot[] memory slots) {
        uint256 count = readWord(body, cursor);
        if (count == 0 || count > MAX_SOURCE_CHAINS || count != chainCount) revert InvalidCount();
        slots = new FinalizationSlot[](count);
        for (uint256 i; i < count; ++i) {
            slots[i].startCheckpointRoot = readRoot(body, cursor);
            slots[i].checkpointCount = uint32(readUint(body, cursor, 32));
            if (slots[i].checkpointCount == 0) revert InvalidCount();
        }
    }

    function _readEndpoints(bytes memory body, Cursor memory cursor, uint256 chainCount) private pure returns (FinalizationEndpoint[] memory endpoints) {
        if (readWord(body, cursor) != chainCount) revert InvalidCount();
        endpoints = new FinalizationEndpoint[](chainCount);
        for (uint256 i; i < chainCount; ++i) {
            endpoints[i].depositRoot = readRoot(body, cursor);
            endpoints[i].depositCount = uint32(readUint(body, cursor, 32));
            endpoints[i].withdrawalRoot = readRoot(body, cursor);
        }
    }

    function _readWindowFinalizationWithdrawals(bytes memory body, Cursor memory cursor, NetworkConfig memory config) private pure returns (WithdrawalLeaf[] memory leaves) {
        uint256 count = readWord(body, cursor);
        if (count > MAX_SETTLEMENT_LEAVES || count > config.maxWithdrawals) revert InvalidCount();
        leaves = new WithdrawalLeaf[](count);
        for (uint256 i; i < count; ++i) {
            WithdrawalLeaf memory leaf;
            leaf.chainIndex = uint8(readUint(body, cursor, 8));
            leaf.senderUserId = uint32(readUint(body, cursor, 32));
            leaf.recipient = readAddress(body, cursor);
            leaf.token = readAddress(body, cursor);
            leaf.amount = readWord(body, cursor);
            leaf.nonce = bytes32(readWord(body, cursor));
            if (leaf.recipient == address(0) || leaf.amount == 0 || leaf.amount >= GOLDILOCKS_PRIME) revert InvalidEncoding();
            _knownChain(config, leaf.chainIndex);
            if (i > 0) {
                WithdrawalLeaf memory previous = leaves[i - 1];
                if (previous.chainIndex > leaf.chainIndex || (previous.chainIndex == leaf.chainIndex && uint256(previous.nonce) >= uint256(leaf.nonce))) revert InvalidOrdering();
            }
            leaves[i] = leaf;
        }
    }

    function _readWindowFinalizationRewards(bytes memory body, Cursor memory cursor, NetworkConfig memory config, bytes32 economicDomain, bytes32 oldRoot, bytes32 newRoot) private pure returns (SourceCheckpointRewardLeaf[] memory leaves) {
        uint256 count = readWord(body, cursor);
        if (count > MAX_SETTLEMENT_LEAVES || count > config.maxRewards) revert InvalidCount();
        if (count == 0 && oldRoot != newRoot) revert InvalidEncoding();
        leaves = new SourceCheckpointRewardLeaf[](count);
        for (uint256 i; i < count; ++i) {
            SourceCheckpointRewardLeaf memory leaf;
            leaf.economicDomain = bytes32(readWord(body, cursor));
            leaf.sourceCheckpointId = uint64(readUint(body, cursor, 64));
            leaf.userId = uint32(readUint(body, cursor, 32));
            leaf.amount = readWord(body, cursor);
            leaf.recipient = readAddress(body, cursor);
            uint256 flag = readUint(body, cursor, 64);
            if (flag > 1) revert InvalidEncoding();
            leaf.initialized = flag == 1;
            if (!leaf.initialized || leaf.recipient == address(0) || leaf.amount == 0 || leaf.sourceCheckpointId > type(uint32).max || leaf.economicDomain != economicDomain) revert InvalidEncoding();
            if (i > 0 && leaves[i - 1].userId >= leaf.userId) revert InvalidOrdering();
            leaves[i] = leaf;
        }
    }

    function _knownChain(NetworkConfig memory config, uint8 chainIndex) private pure {
        for (uint256 i; i < config.chains.length; ++i) if (config.chains[i].chainIndex == chainIndex) return;
        revert InvalidConfig();
    }

    function windowFinalizationOpeningDigest(WindowFinalizationOpening memory opening, bytes32 depositOpeningDigest) internal pure returns (bytes32) {
        bytes memory body = abi.encodePacked(SETTLEMENT, opening.configHash, bytes32(uint256(opening.endCheckpointId)), _hash4Words(opening.endCheckpointRoot), depositOpeningDigest, _u32x8Words(opening.globalDepositRoot), _u32x8Words(opening.globalWithdrawalRoot), bytes32(opening.finalizations.length));
        for (uint256 i; i < opening.finalizations.length; ++i) {
            body = bytes.concat(body, _hash4Words(opening.finalizations[i].startCheckpointRoot), bytes32(uint256(opening.finalizations[i].checkpointCount)));
        }
        for (uint256 i; i < opening.endpoints.length; ++i) {
            FinalizationEndpoint memory endpoint = opening.endpoints[i];
            body = bytes.concat(body, _hash4Words(endpoint.depositRoot), bytes32(uint256(endpoint.depositCount)), _hash4Words(endpoint.withdrawalRoot));
        }
        body = bytes.concat(body, bytes32(opening.withdrawals.length), bytes32(opening.rewards.length), _hash4Words(opening.oldRewardLedgerRoot), _hash4Words(opening.newRewardLedgerRoot), opening.economicDomain, bytes32(_batchCount(opening.withdrawals.length, opening.rewards.length)), opening.batchRoot);
        return keccak256(body);
    }

    function _hash4Words(bytes32 root) private pure returns (bytes memory) {
        return abi.encode(uint64(uint256(root) >> 192), uint64(uint256(root) >> 128), uint64(uint256(root) >> 64), uint64(uint256(root)));
    }

    function _u32x8Words(bytes32 packed) private pure returns (bytes memory) {
        uint256 value = uint256(packed);
        uint256 mask = type(uint32).max;
        return abi.encode((value >> 224) & mask, (value >> 192) & mask, (value >> 160) & mask, (value >> 128) & mask, (value >> 96) & mask, (value >> 64) & mask, (value >> 32) & mask, value & mask);
    }

    function _batchCount(uint256 withdrawals, uint256 rewards) private pure returns (uint256) {
        return _chunks(withdrawals) + _chunks(rewards);
    }

    function _chunks(uint256 count) private pure returns (uint256) {
        return count == 0 ? 0 : (count + 31) / 32;
    }

    function _batchRoot(WindowFinalizationOpening memory opening) private pure returns (bytes32) {
        uint256 withdrawalChunks = _chunks(opening.withdrawals.length);
        uint256 batchCount = withdrawalChunks + _chunks(opening.rewards.length);
        uint256 width = 1;
        while (width < batchCount) width <<= 1;
        bytes32[] memory nodes = new bytes32[](width);
        for (uint256 ordinal; ordinal < width; ++ordinal) {
            nodes[ordinal] = ordinal >= batchCount
                ? keccak256(abi.encodePacked(SETTLEMENT_EMPTY, bytes32(batchCount), bytes32(ordinal)))
                : keccak256(abi.encodePacked(SETTLEMENT_LEAF, bytes32(batchCount), bytes32(ordinal), bytes32(_batchFamily(ordinal, withdrawalChunks)), _batchCommit(opening, ordinal, withdrawalChunks)));
        }
        for (uint256 level = 1; width > 1; ++level) {
            width /= 2;
            for (uint256 i; i < width; ++i) nodes[i] = keccak256(abi.encodePacked(SETTLEMENT_NODE, bytes32(level), nodes[2 * i], nodes[2 * i + 1]));
        }
        return nodes[0];
    }

    function _batchFamily(uint256 ordinal, uint256 withdrawalChunks) private pure returns (uint256) {
        return ordinal < withdrawalChunks ? 2 : 3;
    }

    function _batchCommit(WindowFinalizationOpening memory opening, uint256 ordinal, uint256 withdrawalChunks) private pure returns (bytes32) {
        bool isWithdrawal = ordinal < withdrawalChunks;
        uint256 first = (isWithdrawal ? ordinal : ordinal - withdrawalChunks) * 32;
        uint256 available = isWithdrawal ? opening.withdrawals.length : opening.rewards.length;
        uint256 count = available - first;
        if (count > 32) count = 32;
        bytes memory records = isWithdrawal ? _withdrawalRecords(opening.withdrawals, first, count) : _rewardRecords(opening.rewards, first, count);
        return keccak256(bytes.concat(abi.encodePacked(SETTLEMENT_BATCH, opening.configHash, opening.windowId, bytes32(uint256(opening.endCheckpointId))), _hash4Words(opening.endCheckpointRoot), abi.encode(isWithdrawal ? uint256(2) : uint256(3), ordinal, first, count), records));
    }

    function _withdrawalRecords(WithdrawalLeaf[] memory leaves, uint256 first, uint256 count) private pure returns (bytes memory records) {
        for (uint256 i; i < count; ++i) records = bytes.concat(records, abi.encode(leaves[first + i]));
    }

    function _rewardRecords(SourceCheckpointRewardLeaf[] memory leaves, uint256 first, uint256 count) private pure returns (bytes memory records) {
        for (uint256 i; i < count; ++i) {
            SourceCheckpointRewardLeaf memory leaf = leaves[first + i];
            records = bytes.concat(records, abi.encode(leaf.economicDomain, leaf.sourceCheckpointId, leaf.userId, leaf.amount, leaf.recipient, leaf.initialized ? uint256(1) : uint256(0)));
        }
    }

    function withdrawalFamilyDigest(WindowFinalizationOpening memory opening) internal pure returns (bytes32) {
        bytes memory body = abi.encodePacked(opening.configHash, opening.windowId, bytes32(uint256(opening.endCheckpointId)), _hash4Words(opening.endCheckpointRoot), bytes32(opening.endpoints.length));
        for (uint256 i; i < opening.endpoints.length; ++i) body = bytes.concat(body, _hash4Words(opening.endpoints[i].withdrawalRoot));
        body = bytes.concat(body, bytes32(opening.withdrawals.length));
        for (uint256 i; i < opening.withdrawals.length; ++i) {
            WithdrawalLeaf memory leaf = opening.withdrawals[i];
            body = bytes.concat(body, bytes32(uint256(leaf.chainIndex)), bytes32(uint256(leaf.senderUserId)), bytes32(uint256(uint160(leaf.recipient))), bytes32(uint256(uint160(leaf.token))), bytes32(leaf.amount), leaf.nonce);
        }
        return keccak256(bytes.concat(WITHDRAWAL, body));
    }

    function rewardFamilyDigest(WindowFinalizationOpening memory opening) internal pure returns (bytes32) {
        bytes memory body = abi.encodePacked(opening.configHash, opening.windowId, bytes32(uint256(opening.endCheckpointId)), _hash4Words(opening.endCheckpointRoot), bytes32(opening.rewards.length));
        for (uint256 i; i < opening.rewards.length; ++i) {
            SourceCheckpointRewardLeaf memory leaf = opening.rewards[i];
            body = bytes.concat(body, leaf.economicDomain, bytes32(uint256(leaf.sourceCheckpointId)), bytes32(uint256(leaf.userId)), bytes32(leaf.amount), bytes32(uint256(uint160(leaf.recipient))), bytes32(leaf.initialized ? uint256(1) : uint256(0)));
        }
        return keccak256(bytes.concat(SOURCE_CHECKPOINT_REWARD_OPENING, body));
    }

    function withdrawalPublicationHeader(WindowFinalizationOpening memory opening) internal pure returns (bytes memory header) {
        uint256 count = opening.withdrawals.length;
        bytes memory roots;
        for (uint256 i; i < opening.endpoints.length; ++i) roots = bytes.concat(roots, opening.endpoints[i].withdrawalRoot);
        header = bytes.concat(
            bytes1(WITHDRAWAL_PUBLICATION_FAMILY),
            opening.configHash,
            opening.windowId,
            abi.encodePacked(opening.endCheckpointId, opening.endCheckpointRoot, uint32(1024), uint32(count), uint32(count == 0 ? 0 : 1), uint32(0), uint32(0), uint32(count)),
            roots,
            withdrawalFamilyDigest(opening),
            withdrawalClaimRoot(opening.withdrawals)
        );
        readInclusionAggregateHeader(header);
    }

    function emptyOpeningDigest(InclusionAggregateHeader memory header) private pure returns (bytes32) {
        bytes memory body = abi.encodePacked(header.configHash, header.windowId, bytes32(uint256(header.endCheckpointId)), _hash4Words(header.endCheckpointRoot));
        if (header.family == WITHDRAWAL_PUBLICATION_FAMILY) {
            body = bytes.concat(body, bytes32(header.withdrawalRoots.length));
            for (uint256 i; i < header.withdrawalRoots.length; ++i) body = bytes.concat(body, _hash4Words(header.withdrawalRoots[i]));
            return keccak256(bytes.concat(WITHDRAWAL, body, bytes32(uint256(0))));
        }
        return keccak256(bytes.concat(SOURCE_CHECKPOINT_REWARD_OPENING, body, bytes32(uint256(0))));
    }

    function emptyClaimTreeRoot(uint32 capacity) private pure returns (bytes32) {
        uint256 width = capacity;
        bytes32[] memory layer = new bytes32[](width);
        for (uint256 ordinal; ordinal < width; ++ordinal) layer[ordinal] = keccak256(abi.encodePacked(EMPTY, bytes32(uint256(12)), bytes32(uint256(0)), bytes32(ordinal)));
        for (uint256 level = 1; width > 1; ++level) {
            width /= 2;
            for (uint256 i; i < width; ++i) layer[i] = keccak256(abi.encodePacked(NODE, bytes32(uint256(12)), bytes32(level), layer[2 * i], layer[2 * i + 1]));
        }
        return layer[0];
    }

    function withdrawalClaimRoot(WithdrawalLeaf[] memory leaves) internal pure returns (bytes32) {
        uint256 count = leaves.length;
        uint256 width = 1024;
        bytes32[] memory layer = new bytes32[](width);
        for (uint256 ordinal; ordinal < width; ++ordinal) {
            layer[ordinal] = ordinal < count
                ? keccak256(abi.encodePacked(LEAF, bytes32(uint256(12)), bytes32(count), bytes32(ordinal), withdrawalLeafCommit(abi.encode(leaves[ordinal]))))
                : keccak256(abi.encodePacked(EMPTY, bytes32(uint256(12)), bytes32(count), bytes32(ordinal)));
        }
        for (uint256 level = 1; width > 1; ++level) {
            width /= 2;
            for (uint256 i; i < width; ++i) layer[i] = keccak256(abi.encodePacked(NODE, bytes32(uint256(12)), bytes32(level), layer[2 * i], layer[2 * i + 1]));
        }
        return layer[0];
    }
}
