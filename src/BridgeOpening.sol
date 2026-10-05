// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library BridgeOpening {
    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    bytes32 internal constant CONFIG = keccak256("PsyBridge/TwoArtifact/1/Config");
    bytes32 internal constant A = keccak256("PsyBridge/TwoArtifact/1/A");
    bytes32 internal constant B = keccak256("PsyBridge/TwoArtifact/1/B");
    bytes32 internal constant WINDOW = keccak256("PsyBridge/TwoArtifact/1/Window");
    bytes32 internal constant BATCH = keccak256("PsyBridge/TwoArtifact/1/Batch");
    bytes32 internal constant LEAF = keccak256("PsyBridge/TwoArtifact/1/Leaf");
    bytes32 internal constant EMPTY = keccak256("PsyBridge/TwoArtifact/1/Empty");
    bytes32 internal constant NODE = keccak256("PsyBridge/TwoArtifact/1/Node");
    bytes32 internal constant AGGREGATE_HEADER = keccak256("PsyBridge/TwoArtifact/1/AggregateHeader");
    uint256 internal constant CLAIM_TREE_MAX_CAPACITY = 131072;
    uint8 internal constant WITHDRAWAL_PUBLICATION_FAMILY = 2;
    uint8 internal constant REWARD_PUBLICATION_FAMILY = 3;

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
    struct ChainEnd { uint8 chainIndex; bytes32 depositRoot; uint32 depositCount; bytes32 withdrawalRoot; }
    struct AOpening {
        bytes32 configHash; bytes32 windowId; uint64 endCheckpointId; bytes32 endCheckpointRoot;
        ChainStart[] starts; DepositTransition[] deposits; DepositLeaf[] depositLeaves; bytes32 statementA;
    }
    struct BOpening { AOpening a; ChainEnd[] ends; WithdrawalLeaf[] withdrawals; RewardLeaf[] rewards; bytes32 statementB; }
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
        bytes32 oldNullifierRoot;
        bytes32 newNullifierRoot;
        bytes32 openingDigest;
        bytes32 claimTreeRoot;
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
    function readA(bytes memory body, NetworkConfig memory config) internal pure returns (AOpening memory opening) {
        Cursor memory c;
        opening = readAFields(body, c, config);
        if (c.offset != body.length) revert InvalidEncoding();
    }
    function readAFields(bytes memory body, Cursor memory c, NetworkConfig memory config) private pure returns (AOpening memory a) {
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
        bytes32 root = batchRoot(body, recordsStart, count, 7, 1, a);
        a.statementA = keccak256(bytes.concat(A, slice(body, 0, projectionEnd), abi.encode(count, (count + 31) / 32, root)));
    }
    function readB(bytes memory body, NetworkConfig memory config) internal pure returns (BOpening memory b) {
        Cursor memory c;
        b.a = readAFields(body, c, config);
        uint256 endsStart = c.offset;
        uint256 n = readWord(body, c);
        if (n != config.chains.length) revert InvalidCount();
        b.ends = new ChainEnd[](n);
        for (uint256 i; i < n; ++i) {
            ChainEnd memory end;
            end.chainIndex = uint8(readUint(body, c, 8));
            end.depositRoot = readRoot(body, c);
            end.depositCount = uint32(readUint(body, c, 32));
            end.withdrawalRoot = readRoot(body, c);
            if (end.chainIndex != config.chains[i].chainIndex) revert InvalidOrdering();
            if (end.depositRoot != b.a.deposits[i].newRoot || end.depositCount != b.a.deposits[i].newCount) revert InvalidDepositState();
            b.ends[i] = end;
        }
        bytes memory ends = slice(body, endsStart, c.offset);
        uint256 count = readWord(body, c);
        if (count > config.maxWithdrawals) revert InvalidCount();
        uint256 recordsStart = c.offset;
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
            while (chain < n && config.chains[chain].chainIndex < leaf.chainIndex) ++chain;
            if (chain == n || config.chains[chain].chainIndex != leaf.chainIndex) revert InvalidOrdering();
            if (leaf.recipient == address(0) || leaf.amount == 0 || leaf.amount >= GOLDILOCKS_PRIME) revert InvalidEncoding();
            if (i != 0) {
                WithdrawalLeaf memory previous = b.withdrawals[i - 1];
                if (previous.chainIndex > leaf.chainIndex || (previous.chainIndex == leaf.chainIndex && previous.nonce >= leaf.nonce)) revert InvalidOrdering();
            }
            b.withdrawals[i] = leaf;
        }
        bytes32 withdrawalRoot = batchRoot(body, recordsStart, count, 6, 2, b.a);
        bytes memory withdrawalProjection = abi.encode(count, (count + 31) / 32, withdrawalRoot);
        count = readWord(body, c);
        if (count > config.maxRewards) revert InvalidCount();
        recordsStart = c.offset;
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
            if (leaf.claimCheckpointId < config.rewardCutover || leaf.claimCheckpointId >= config.rewardEndExclusive || leaf.claimCheckpointId > b.a.endCheckpointId) revert InvalidCursor();
            if (i != 0) {
                RewardLeaf memory previous = b.rewards[i - 1];
                if (previous.claimCheckpointId > leaf.claimCheckpointId || (previous.claimCheckpointId == leaf.claimCheckpointId && previous.nullifierIndex >= leaf.nullifierIndex)) revert InvalidOrdering();
            }
            b.rewards[i] = leaf;
        }
        if (c.offset != body.length) revert InvalidEncoding();
        bytes32 rewardRoot = batchRoot(body, recordsStart, count, 6, 3, b.a);
        b.statementB = keccak256(bytes.concat(B, b.a.statementA, ends, withdrawalProjection, abi.encode(count, (count + 31) / 32, rewardRoot)));
    }
    function batchRoot(bytes memory body, uint256 start, uint256 count, uint256 recordWords, uint256 family, AOpening memory a) private pure returns (bytes32) {
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
            header.oldNullifierRoot = readCanonicalHash4(body, offset);
            offset += 32;
            header.newNullifierRoot = readCanonicalHash4(body, offset);
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
            if (header.segmentIndex != 0 || header.firstOrdinal != 0 || header.count != 0 || header.openingDigest != bytes32(0) || header.claimTreeRoot != bytes32(0)) revert InvalidCount();
        } else {
            if (header.segmentIndex >= segments) revert InvalidCount();
            uint256 first = uint256(header.segmentIndex) * capacity;
            if (first > type(uint32).max || header.firstOrdinal != first) revert InvalidCount();
            uint256 remaining = uint256(total) - first;
            uint256 expected = remaining < capacity ? remaining : uint256(capacity);
            if (header.count == 0 || header.count != expected) revert InvalidCount();
        }
        if (header.family == WITHDRAWAL_PUBLICATION_FAMILY) {
            if (header.withdrawalRoots.length == 0 || header.withdrawalRoots.length > 256 || header.oldNullifierRoot != bytes32(0) || header.newNullifierRoot != bytes32(0)) revert InvalidCount();
        } else if (header.totalCount == 0 && header.oldNullifierRoot != header.newNullifierRoot) {
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
}
