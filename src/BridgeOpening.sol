// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEthereumRewardPayer} from "./IEthereumRewardPayer.sol";

library BridgeOpening {
    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    bytes32 internal constant CONFIG = keccak256("PsyBridge/TwoArtifact/1/Config");
    uint256 internal constant MAX_OPENING_CHAINS = 8;
    uint256 internal constant MAX_OPENING_RECORDS = 32;
    uint32 internal constant REWARD_CONTRACT_ID = 7;

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
        uint32 maxWithdrawals;
        uint32 maxRewards;
    }
    struct BridgeChainRow {
        uint8 chainIndex;
        uint32 startCheckpointId;
        bytes32 startCheckpointRoot;
        bytes32 oldDepositRoot;
        bytes32 newDepositRoot;
        uint32 oldCount;
        uint32 newCount;
    }
    struct WithdrawalBurnRecord {
        uint8 chainIndex;
        uint32 userId;
        uint32 contractId;
        bytes32 nonce;
        address recipient;
        uint256 amount;
    }
    struct BridgeOpeningBody {
        bytes32 configHash;
        uint32 endCheckpointId;
        bytes32 endCheckpointRoot;
        bytes32 endUserRoot;
        BridgeChainRow[] chains;
        DepositLeaf[] deposits;
        WithdrawalBurnRecord[] withdrawals;
        IEthereumRewardPayer.RewardClaim[] rewards;
        bytes32 openingDigest;
    }
    struct DepositLeaf { uint8 chainIndex; uint32 absoluteIndex; bytes32 shieldAddress; address token; bytes32 l2TokenContractId; uint256 amount; bytes32 noteCommitment; }
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
        config.maxWithdrawals = uint32(readUint(body, c, 32));
        config.maxRewards = uint32(readUint(body, c, 32));
        if (c.offset != body.length) revert InvalidEncoding();
        if (config.rewardPayer == address(0) || config.rewardToken == address(0) || config.rewardPerClaim == 0) revert InvalidConfig();
        if (config.maxWithdrawals > 1024 || config.maxRewards > 1024) revert InvalidCount();
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
    function proofInputs(bytes32 digest) internal pure returns (uint256[2] memory) {
        return [uint256(uint128(uint256(digest) >> 128)), uint256(uint128(uint256(digest)))];
    }
    function readBridgeOpening(bytes memory body, NetworkConfig memory config) internal pure returns (BridgeOpeningBody memory opening) {
        Cursor memory cursor;
        if (readUint(body, cursor, 32) != 4) revert InvalidConfig();
        opening.configHash = bytes32(readWord(body, cursor));
        if (opening.configHash != config.configHash) revert InvalidConfig();
        opening.endCheckpointId = uint32(readUint(body, cursor, 32));
        opening.endCheckpointRoot = readRoot(body, cursor);
        opening.endUserRoot = readRoot(body, cursor);
        uint256 chains = readUint(body, cursor, 32);
        uint256 deposits = readUint(body, cursor, 32);
        uint256 withdrawals = readUint(body, cursor, 32);
        uint256 rewards = readUint(body, cursor, 32);
        if (chains == 0 || chains > MAX_OPENING_CHAINS || chains != config.chains.length) revert InvalidCount();
        if (deposits > MAX_OPENING_RECORDS || withdrawals > MAX_OPENING_RECORDS || rewards > MAX_OPENING_RECORDS) revert InvalidCount();
        opening.chains = new BridgeChainRow[](chains);
        for (uint256 i; i < chains; ++i) {
            BridgeChainRow memory row;
            row.chainIndex = uint8(readUint(body, cursor, 8));
            row.startCheckpointId = uint32(readUint(body, cursor, 32));
            row.startCheckpointRoot = readRoot(body, cursor);
            row.oldDepositRoot = readRoot(body, cursor);
            row.newDepositRoot = readRoot(body, cursor);
            row.oldCount = uint32(readUint(body, cursor, 32));
            row.newCount = uint32(readUint(body, cursor, 32));
            if (row.chainIndex != config.chains[i].chainIndex) revert InvalidOrdering();
            if (row.startCheckpointId < config.chains[i].bootstrapId || row.startCheckpointId > opening.endCheckpointId) revert InvalidCursor();
            if (row.startCheckpointId == config.chains[i].bootstrapId && row.startCheckpointRoot != config.chains[i].bootstrapRoot) revert InvalidCursor();
            if (row.startCheckpointId == opening.endCheckpointId && row.startCheckpointRoot != opening.endCheckpointRoot) revert InvalidCursor();
            if (row.newCount < row.oldCount) revert InvalidCount();
            if (row.newCount == row.oldCount && row.newDepositRoot != row.oldDepositRoot) revert InvalidDepositState();
            opening.chains[i] = row;
        }
        opening.deposits = new DepositLeaf[](deposits);
        uint256 rowIndex;
        uint256 consumed;
        for (uint256 i; i < deposits; ++i) {
            while (rowIndex < chains && consumed == uint256(opening.chains[rowIndex].newCount) - opening.chains[rowIndex].oldCount) {
                ++rowIndex;
                consumed = 0;
            }
            if (rowIndex == chains) revert InvalidCount();
            DepositLeaf memory leaf;
            leaf.chainIndex = uint8(readUint(body, cursor, 8));
            leaf.absoluteIndex = uint32(readUint(body, cursor, 32));
            leaf.shieldAddress = bytes32(readWord(body, cursor));
            leaf.token = readAddress(body, cursor);
            leaf.l2TokenContractId = bytes32(readWord(body, cursor));
            leaf.amount = readWord(body, cursor);
            leaf.noteCommitment = bytes32(readWord(body, cursor));
            if (leaf.chainIndex != opening.chains[rowIndex].chainIndex || leaf.absoluteIndex != uint256(opening.chains[rowIndex].oldCount) + consumed) revert InvalidOrdering();
            opening.deposits[i] = leaf;
            ++consumed;
        }
        while (rowIndex < chains && consumed == uint256(opening.chains[rowIndex].newCount) - opening.chains[rowIndex].oldCount) {
            ++rowIndex;
            consumed = 0;
        }
        if (rowIndex != chains) revert InvalidCount();
        opening.withdrawals = new WithdrawalBurnRecord[](withdrawals);
        for (uint256 i; i < withdrawals; ++i) {
            if (readUint(body, cursor, 8) != 1) revert InvalidEncoding();
            WithdrawalBurnRecord memory record;
            record.chainIndex = uint8(readUint(body, cursor, 8));
            record.userId = uint32(readUint(body, cursor, 32));
            record.contractId = uint32(readUint(body, cursor, 24));
            record.nonce = bytes32(readWord(body, cursor));
            if (readUint(body, cursor, 64) != 0 || readUint(body, cursor, 64) != 0 || readUint(body, cursor, 32) != 0) revert InvalidEncoding();
            record.recipient = readAddress(body, cursor);
            record.amount = readWord(body, cursor);
            if (record.recipient == address(0) || record.amount == 0 || record.amount >= GOLDILOCKS_PRIME) revert InvalidEncoding();
            chainOrdinal(config, record.chainIndex);
            if (i != 0) {
                WithdrawalBurnRecord memory previous = opening.withdrawals[i - 1];
                if (
                    previous.chainIndex > record.chainIndex
                        || (previous.chainIndex == record.chainIndex && (
                            previous.userId > record.userId
                                || (previous.userId == record.userId && (
                                    previous.contractId > record.contractId
                                        || (previous.contractId == record.contractId && uint256(previous.nonce) >= uint256(record.nonce))
                                ))
                        ))
                ) revert InvalidOrdering();
            }
            opening.withdrawals[i] = record;
        }
        opening.rewards = new IEthereumRewardPayer.RewardClaim[](rewards);
        for (uint256 i; i < rewards; ++i) {
            if (readUint(body, cursor, 8) != 2) revert InvalidEncoding();
            uint8 chainIndex = uint8(readUint(body, cursor, 8));
            if (chainIndex != config.ethereumIndex) revert InvalidConfig();
            IEthereumRewardPayer.RewardClaim memory claim;
            claim.userId = uint32(readUint(body, cursor, 32));
            if (readUint(body, cursor, 32) != REWARD_CONTRACT_ID) revert InvalidEncoding();
            claim.oldNullifierRoot = readRoot(body, cursor);
            claim.newNullifierRoot = readRoot(body, cursor);
            claim.count = uint32(readUint(body, cursor, 32));
            claim.recipient = readAddress(body, cursor);
            claim.amount = readWord(body, cursor);
            if (claim.recipient == address(0) || claim.amount == 0) revert InvalidEncoding();
            opening.rewards[i] = claim;
        }
        if (cursor.offset != body.length) revert InvalidEncoding();
        opening.openingDigest = keccak256(abi.encodePacked(keccak256("PsyBridge/Opening/4"), body));
    }
}
