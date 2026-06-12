// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IFaucetMintableToken {
    function mint(address to, uint256 amount) external;
}

/**
 * @title TokenFaucetManager
 * @notice Owner-managed test-token faucet. Users claim configured tokens, while
 * this contract owns the token contracts and performs the owner-only mint.
 */
contract TokenFaucetManager is Initializable, OwnableUpgradeable {
    struct TokenRule {
        uint128 dripAmount;
        uint64 cooldownBlocks;
        bool enabled;
    }

    address[] private _tokens;
    TokenRule[] private _configs;
    mapping(address => uint256) private _indexPlusOne;
    mapping(address => mapping(address => uint64)) public lastClaimBlock;

    event TokenConfigured(address indexed token, bool enabled, uint256 dripAmount, uint64 cooldownBlocks);
    event TokenRemoved(address indexed token);
    event Claimed(address indexed user, address indexed token, uint256 amount, uint64 nextEligibleBlock);

    error TokenAlreadyListed(address token);
    error TokenNotListed(address token);
    error TokenDisabled(address token);
    error InvalidDripAmount();
    error ClaimCooldown(address token, uint64 nextEligibleBlock);

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function configs() external view returns (TokenRule[] memory) {
        return _configs;
    }

    function tokenRule(address token) external view returns (TokenRule memory) {
        uint256 i = _indexPlusOne[token];
        if (i == 0) revert TokenNotListed(token);
        return _configs[i - 1];
    }

    function isListed(address token) public view returns (bool) {
        return _indexPlusOne[token] != 0;
    }

    function addToken(address token, bool enabled, uint256 dripAmount, uint64 cooldownBlocks) external onlyOwner {
        if (dripAmount == 0) revert InvalidDripAmount();
        if (isListed(token)) revert TokenAlreadyListed(token);

        _tokens.push(token);
        _configs.push(TokenRule({
            dripAmount: uint128(dripAmount),
            cooldownBlocks: cooldownBlocks,
            enabled: enabled
        }));
        _indexPlusOne[token] = _tokens.length;

        emit TokenConfigured(token, enabled, dripAmount, cooldownBlocks);
    }

    function updateTokenConfig(address token, bool enabled, uint256 dripAmount, uint64 cooldownBlocks) external onlyOwner {
        if (dripAmount == 0) revert InvalidDripAmount();
        uint256 i = _indexPlusOne[token];
        if (i == 0) revert TokenNotListed(token);

        _configs[i - 1] = TokenRule({
            dripAmount: uint128(dripAmount),
            cooldownBlocks: cooldownBlocks,
            enabled: enabled
        });

        emit TokenConfigured(token, enabled, dripAmount, cooldownBlocks);
    }

    function removeToken(address token) external onlyOwner {
        uint256 idxPlusOne = _indexPlusOne[token];
        if (idxPlusOne == 0) revert TokenNotListed(token);

        uint256 idx = idxPlusOne - 1;
        uint256 last = _tokens.length - 1;
        if (idx != last) {
            address movedToken = _tokens[last];
            _tokens[idx] = movedToken;
            _configs[idx] = _configs[last];
            _indexPlusOne[movedToken] = idx + 1;
        }
        _tokens.pop();
        _configs.pop();
        delete _indexPlusOne[token];

        emit TokenRemoved(token);
    }

    function claim(address token) external {
        _claim(msg.sender, token);
    }

    function claimAll() external {
        uint256 len = _tokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = _tokens[i];
            TokenRule memory rule = _configs[i];
            if (!rule.enabled || rule.dripAmount == 0) continue;

            uint64 nowBlock = uint64(block.number);
            uint64 nextEligible = lastClaimBlock[msg.sender][token] + rule.cooldownBlocks;
            if (nowBlock < nextEligible) continue;

            lastClaimBlock[msg.sender][token] = nowBlock;
            IFaucetMintableToken(token).mint(msg.sender, rule.dripAmount);
            emit Claimed(msg.sender, token, rule.dripAmount, nowBlock + rule.cooldownBlocks);
        }
    }

    function canClaim(address user, address token) external view returns (bool ok, uint64 nextEligibleBlock) {
        uint256 i = _indexPlusOne[token];
        if (i == 0) return (false, 0);

        TokenRule memory rule = _configs[i - 1];
        if (!rule.enabled || rule.dripAmount == 0) return (false, 0);

        uint64 nextBlock = lastClaimBlock[user][token] + rule.cooldownBlocks;
        if (uint64(block.number) < nextBlock) return (false, nextBlock);
        return (true, nextBlock);
    }

    function _claim(address user, address token) internal {
        uint256 i = _indexPlusOne[token];
        if (i == 0) revert TokenNotListed(token);

        TokenRule memory rule = _configs[i - 1];
        if (!rule.enabled) revert TokenDisabled(token);
        if (rule.dripAmount == 0) revert InvalidDripAmount();

        uint64 nowBlock = uint64(block.number);
        uint64 nextEligible = lastClaimBlock[user][token] + rule.cooldownBlocks;
        if (nowBlock < nextEligible) revert ClaimCooldown(token, nextEligible);

        lastClaimBlock[user][token] = nowBlock;
        IFaucetMintableToken(token).mint(user, rule.dripAmount);

        emit Claimed(user, token, rule.dripAmount, nowBlock + rule.cooldownBlocks);
    }
}
