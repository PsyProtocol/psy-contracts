// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Canonical network configuration consumed by the reward payer.
library RewardNetworkConfig {
    uint256 internal constant GOLDILOCKS_PRIME = 18446744069414584321;
    bytes32 internal constant CONFIG = keccak256("PsyBridge/TwoArtifact/1/Config");

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
    struct Cursor { uint256 offset; }
    error InvalidEncoding();
    error InvalidConfig();
    error InvalidOrdering();
    error InvalidCount();

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
}
