# psy-contracts

Dual-stack contract workspace supporting both Foundry and Hardhat.

## Layout
- `src/`: shared Solidity sources
- `test/foundry/`: Forge tests
- `test/hardhat/`: Hardhat tests
- `script/`: deployment or maintenance scripts

## Commands
- `forge test -C .`
- `npm install`
- `npm run test:hardhat`
- `npm run build`
- `npm run deploy:localhost`
- `npm run deploy:devnet`
- `npm run deploy:keystore:localhost`
- `npm run deploy:keystore:sepolia`
- `npm run deploy:keystore:ethereum`

## Notes
- Solidity version pinned to `0.8.24`
- Optimizer enabled (`runs=200`)
- Hardhat source path points to `src/` to share the same contracts with Foundry
- `StateManager.finalize` with a zero withdrawal root stays open for empty catch-up finalizes until a non-zero withdrawal root has been finalized (`WithdrawalBootstrapExpired` after that). The empty proof is the all-zero leaf and siblings. Any other proof is checked with the existing top-tree verifier and reverts `InvalidWithdrawalMerkleProof` when it does not hash to the zero root.

## Token reward claim

`PsyToken.claimReward` is the reward entry. It reverts unless `block.chainid` is 1, 31337, or 11155111 (`WrongChain`), before any mint or claimed-state write. A valid claim mints `totalAmount` of PSY (9 decimals) to `recipient` and sets `claimed[userId][checkpointId]` for each strictly increasing checkpoint id (at most 64). The same pair cannot be claimed again (`AlreadyClaimed`). Owner `mint` is separate and is not a claim.

The checkpoint tree root must have a nonzero `StateManager.checkpointTreeRootCheckpointId` within the finalized tip (`UnrecognizedRewardRoot` otherwise). There is no clean flag. The mapping is the single source of truth; there is no root array or count. Ordinary finalization preserves historical roots. A real force-set, including same-height replacement or an empty registry, writes only the five state fields: it does not pause finalization or claims, does not revoke mappings, and does not register its target as a proved checkpoint-tree root. Administrators revoke named abandoned roots with `revokeCheckpointTreeRoots`; unaffected historical roots remain registered. Later alternate-branch advancement cannot restore revoked roots; only a new proof finalization can register them again. Claimed pairs never reset. The proof is 256 bytes decoded as `uint256[8]` and checked by the address stored at `REWARD_CLAIM_VERIFIER_ID`. The verifier input is the high and low 128 bits of `keccak256(abi.encode(commitment))`, where `commitment = keccak256(abi.encode(CLAIM_DOMAIN, token, stateManager, userId, recipient, checkpointRoot, count, totalAmount, paddedIds))`, `CLAIM_DOMAIN = keccak256("PsyReward/TokenCheckpointClaim/1")`, and unused id slots are zero.

No real Groth16 verifier is deployed for this path. `forge test -C . --match-contract PsyTokenClaimTest` is a component test: `RewardClaimDigestVerifier` accepts one explicit 8-word test proof for the digest `PsyToken` computed. It is not an end-to-end payout and not real-proof evidence.


## Contract Verification

After deployment, verify contracts on Etherscan:

```bash
# Hardhat-native verification (default)
npx hardhat verify-contracts --network <network>

# Or via Makefile (from repo root)
make verify-contracts NETWORK=sepolia
make verify-contracts-ethereum

# Foundry forge verify-contract (alternative)
ETHERSCAN_VERIFICATION_PROVIDER=foundry npx hardhat verify-contracts --network sepolia
```

### Configuration
All settings are read from env vars:
- `ETHERSCAN_KEY`: Primary Etherscan API key (required)
- `SEPOLIA_ETHERSCAN_KEY`: Override for Sepolia (falls back to ETHERSCAN_KEY)
- `MAINNET_ETHERSCAN_KEY`: Override for Ethereum mainnet (falls back to ETHERSCAN_KEY)
- `ETHERSCAN_VERIFICATION_PROVIDER`: `hardhat` (default) or `foundry`
- `ETHERSCAN_VERIFICATION_MAX_RETRIES`: Max retries for Hardhat verification (default: 3)

### How It Works

1. **Deploy**脚本结束时，`deployments/<network>/` 下的 JSON 文件包含每个合约的部署元数据（address、constructorArgs、libraries）
2. **Verify**时，`verify-contracts` task 自动扫描 `deployments/<network>/` 目录，读取部署信息
3. 对每个合约（含 `_Implementation`，自动跳过 `_Proxy`），按以下方式验证：
   - **Hardhat**（默认）：调用 `verify:verify` task，带自动重试
   - **Foundry**（`ETHERSCAN_VERIFICATION_PROVIDER=foundry`）：构建 `forge verify-contract` 命令，用 `cast abi-encode` 编码构造参数

验证覆盖的合约类型：
| 类型 | 例子 | 说明 |
|------|------|------|
| 普通合约 | StateManager, Bridge | 单独部署，直接验证 |
| 代理合约 | PsyAddressesProvider_Proxy | OpenZeppelin Transparent Proxy，验证构造函数参数(impl, admin, data) |
| 实现合约 | PsyAddressesProvider_Implementation | 验证实现合约的构造函数参数 |

> 参考实现：paraspace-core 的 `tasks/dev/verifyContracts.ts` → `helpers/contracts-helpers.ts:verifyContracts()`，支持 Hardhat 和 Foundry 双模式。

## Deploy Runbook

### 1) Required env vars
- `KEYSTORE_PATH`: encrypted deployer keystore path
- `WALLET_PASSWORD`: keystore password
- RPC for the selected network: `LOCALHOST_RPC_URL`, `LOCALHOST_BSC_RPC_URL`,
  `LOCALHOST_BASE_RPC_URL`, `SEPOLIA_RPC_URL`, `BSC_TESTNET_RPC_URL`, or
  `BASE_SEPOLIA_RPC_URL`
- Optional per-network WETH envs in `helper-hardhat-config.ts` (`ETH_WETH`, `ARB_WETH`, ...)
- `PSY_DEPLOYMENTS_DIR`: optional deployments directory. Default is `./deployments`, resolved from this package root. `deploy/008_export_deployed_contracts.ts` reads and writes that same directory.

Direct deploy private keys are intentionally disabled. Use `scripts/deploy-with-keystore.mjs` or the `deploy:keystore:*` npm scripts. The wrapper unlocks the keystore in-process and does not print the key. It runs `npx --no-install hardhat`, so a missing local install fails instead of fetching packages.

### 2) Config files
- Network deploy config is loaded from `config/<network>.json`
- For non-local networks, do not use placeholder governance addresses (`0x...01`, `0x...02`)
- `admin` is the initial `DefaultProxyAdmin` owner and ACL default admin.
- Set `owner`, `bridgeAdmin`, `routerAdmin`, and `stateManagerAdmin` explicitly; do not assume they are interchangeable with `admin`.
### 3) Local deploy
- `KEYSTORE_PATH=... WALLET_PASSWORD=... LOCALHOST_RPC_URL=http://127.0.0.1:8545 npm run deploy:keystore:localhost`
- `KEYSTORE_PATH=... WALLET_PASSWORD=... LOCALHOST_BSC_RPC_URL=http://127.0.0.1:9545 npm run deploy:keystore:localhost-bsc`
- `KEYSTORE_PATH=... WALLET_PASSWORD=... LOCALHOST_BASE_RPC_URL=http://127.0.0.1:10545 npm run deploy:keystore:localhost-base`

### 4) Public testnet deploy
- `KEYSTORE_PATH=... WALLET_PASSWORD=... SEPOLIA_RPC_URL=https://... npm run deploy:keystore:sepolia`
- `KEYSTORE_PATH=... WALLET_PASSWORD=... BSC_TESTNET_RPC_URL=https://... npm run deploy:keystore:bsc-testnet`
- `KEYSTORE_PATH=... WALLET_PASSWORD=... BASE_SEPOLIA_RPC_URL=https://... npm run deploy:keystore:base-sepolia`

Every deploy fails closed when the RPC `eth_chainId` differs from
`protocol-config`. The final deployment export also verifies the on-chain
`StateManager.l1ChainIndex()` before writing `deployed-contracts.json`.

#### Test token metadata

New `USDTToken` deployments on Ethereum Sepolia, BSC Testnet, and Base Sepolia
use `Psy USDT` for ERC-20 `name()` and `pUSDT` for `symbol()` (lowercase `p`,
uppercase `USDT`). Local deployments use the same contract. This is Psy testnet USDT
for bridge testing, not an official Tether token and not redeemable for USD.
Decimals remain 6 and the deployment script still mints 1 billion tokens.

`USDTToken`, the protocol key `USDT`, L2 token ID 4, and the deployment JSON
keys remain unchanged for compatibility. This change only renames the on-chain
test token; it does not update DApp or wallet display labels. The configured
Ethereum mainnet USDT address is unchanged.

Existing deployed tokens cannot be renamed: they have no metadata setter or
upgrade proxy. Do not overwrite existing deployment addresses to apply this
change. A fresh deployment or separately reviewed migration must account for
Router mappings, Faucet configuration, outstanding claims, and old balances.

After an authorized deployment, verify `name()`, `symbol()`, and `decimals()`
on each chain. Provide the chain ID, new token address, verified source code,
and faucet address to the wallet security team for review. Renaming does not
automatically remove an existing Blockaid or MetaMask warning.

### 5) Post-deploy sanity checks
- `StateManager.bridge == Bridge`
- `StateManager.proposer == expected proposer`
- `Router.bridge == Bridge`
- `Router.defaultERC20Gateway == ERC20Gateway`
- `Router.ethGateway == ETHGateway`
- `StateManager.zkVerifier != address(0)`
- deployment `chainId` equals RPC `eth_chainId`
- deployment `protocol.chain.l1ChainIndex` equals `StateManager.l1ChainIndex()`

### 6) Role model
- `StateManager.appendDeposit`: only Bridge
- `StateManager.finalize`: only Proposer
- `Bridge.recordDeposit`: disabled; the supported path is Router -> Gateway -> Bridge.recordDepositFromGateway
- `Bridge.recordDepositFromGateway`: caller must match Router-resolved gateway

`WITHDRAWAL_BATCH_CLAIM_SLOT_WORDS` is 35 words per slot; word 34 carries the slot's own `token_contract_id` (a `uint32`). Medium withdrawals create `pendingWithdrawals[withdrawalId]` with `claimableAt` and emit `WithdrawalPendingCreated`; after that deadline, `claimPendingWithdrawal` pays the original recipient. Large withdrawals or withdrawals whose next cumulative total exceeds `totalWithdrawalCap` require the governance `withdrawalForceClaimExecutor` to call `forceClaimWithdrawal` after their stored deadline. Governance cannot bypass the delay or redirect funds. Both paths consume `claimedNullifiers[withdrawalId]` and add to the lifetime token total before transfer; settlement never decrements that total. `withdrawalRequiresGovernance(withdrawalId)` reports the stored permission. Pre-upgrade pending entries without a tier require governance while preserving their deadline. Local medium/large delays are one hour/seven days; non-local deployments require reviewed manifests.

### Whole revert vs per-slot failure

These failures revert the whole transaction with zero effects — no nullifier written, no total changed, no event emitted:

| Condition | Error |
|---|---|
| `withdrawalClaimVerifier == address(0)` | `VerifierNotSet` |
| Groth16 verification fails | the verifier's own revert |
| `realCount == 0` or `realCount > 32` | `InvalidRealCount` |
| proof root is neither `withdrawalSubtreeRoot()` nor in `knownWithdrawalSubtreeRoots` | `InvalidWithdrawalProof` |
| `bridgeUserId != BRIDGE_USER_ID()` | `InvalidPublicInputs` |
| slot-data commit differs from the proof's `batchCommit` | `InvalidWithdrawalProof` |
| any padding slot (index `>= realCount`) is nonzero | `InvalidPublicInputs` |

The commit and padding checks run before any state change, so slot data the proof never committed to can neither register nor emit. Anything not in the reason table below also reverts the whole transaction; an unexpected internal failure is never swallowed per slot.

A failure inside the table skips only that slot: the nullifier stays unconsumed, the total is untouched, and the other slots still register. The function returns two parallel arrays holding the failed slots only, compacted and in ascending slot order:

- `failedSlotIndexes` — slot positions `0..realCount-1`
- `failureReasons` — the `CLAIM_REASON_*` code for each

A mined transaction carries no return data. The receipt is the record, and it always ends with one `WithdrawalClaimBatchResult(batchCommit, realCount, succeededCount, failedCount)` where `succeededCount + failedCount == realCount`. Each failed slot also emits `WithdrawalClaimItemFailed(withdrawalId, slotIndex, reason)`. `withdrawalId` is the first indexed topic — the keccak of the slot's 140-byte identity, see the reason 5 section; `slotIndex` is the second indexed topic; `reason` is the non-indexed data word. The same withdrawal identity can appear in both a `WithdrawalPendingCreated` and a `WithdrawalClaimItemFailed` when two slots produce it, and only `slotIndex` tells them apart.

### Reason codes

`0` means the slot was valid. `12..255` are reserved and never emitted. The eleven codes, exactly as named in `src/Bridge.sol`:

| Code | Name | Meaning |
|---|---|---|
| 1 | `CLAIM_REASON_ADDRESS_HIGH_BITS` | recipient or token word has bits set above bit 160 |
| 2 | `CLAIM_REASON_WRONG_DESTINATION_CHAIN` | slot destination chain is not `StateManager.l1ChainIndex()` |
| 3 | `CLAIM_REASON_ZERO_ADDRESS` | recipient is the zero address |
| 4 | `CLAIM_REASON_ZERO_AMOUNT` | amount is zero |
| 5 | `CLAIM_REASON_NULLIFIER_ALREADY_CLAIMED` | `claimedNullifiers[withdrawalId]` is already set |
| 6 | `CLAIM_REASON_TOKEN_NOT_CONFIGURED` | the token has no flow config |
| 7 | `CLAIM_REASON_REGISTRATION_PAUSED` | effective pause flags include withdrawal-registration pause |
| 8 | `CLAIM_REASON_AMOUNT_OUT_OF_RANGE` | amount is zero |
| 9 | `CLAIM_REASON_TOTAL_AMOUNT_OVERFLOW` | `amount + totalWithdrawalAmount(token)` would overflow `uint256` |
| 10 | `CLAIM_REASON_CLAIMABLE_AT_OVERFLOW` | `block.timestamp + delay` would not fit in `uint64` |
| 11 | `CLAIM_REASON_TOKEN_MAPPING_MISMATCH` | the slot's `token_contract_id` (word 34) is not the Router's dual binding of the token: `l1ToL2Token(token)` is not the slot id, or `l2ToL1Token(slot id)` is not the token |

Checked in that order, so the first match wins: a zero amount whose address also has high bits reports `1`, not `4`. Code 11 comes from the Router dual read between the nullifier check and `_withdrawalRegistrationCheck`; the withdrawal slot carries its own burning L2 contract id in word 34, and that id drives both reads — `l1ToL2Token(token)` must equal the slot's id and `l2ToL1Token(slot id)` must resolve back to the token (`bytes32(0)` is a real L2 id, so an all-zero pair binds only a nonzero token). Codes 6–10 come from `_withdrawalRegistrationCheck`, which also selects the delay tier (`small`, `medium`, or `large`; the large tier also applies when the next total would pass `totalWithdrawalCap`).

`Router.setTokenMapping` keeps one L2 id for one L1 token. `isL2TokenOccupied` is appended after `l2ToL1Token` and is the occupancy record: native's reverse word is `address(0)`, so a zero reverse is not "free", and `bytes32(0)` is PSY's real id, so native's forward cannot be zero (`NativeL2TokenZero`). A different L1 already holding the id reverts `L2TokenOccupied` with that holder, including `address(0)` for native, and writes nothing. An id with no holder is free, including id 0 before PSY is mapped. The same pair returns without storage writes. Mapping an L1 token to a new free id is allowed and does not clear either direction. The previous id stays occupied. A native remap writes that reservation only for its previous nonzero id, because that reverse word is `address(0)`; the first native mapping does not reserve id 0. There is no migration. An unrecorded id is still held when its reverse owner is nonzero, or, for a nonzero id only, when native's forward already names it. A pre-upgrade pair that does not match is left unchanged and cannot be repaired by this call.


### Reason 5 and repeated identities

Reason 5 covers both an identity consumed by an earlier transaction and a duplicate of a slot earlier in the same batch. The first slot registers and emits `WithdrawalPendingCreated`; every later slot producing the same identity fails with reason 5 and emits `WithdrawalClaimItemFailed` for its own slot index. Nothing about the first registration changes.

Reason 5 says only that the identity is consumed. The identity is the keccak of the slot's full tuple `(senderUserId, recipient, token, amount, nonce, destinationChainIndex, token_contract_id)` — the same 140 big-endian bytes the Poseidon leaf hashes — so two slots collide only when the whole tuple matches. On-chain proof that a consumed identity is this withdrawal's: the still-pending `pendingWithdrawals(withdrawalId)` entry, or, once that entry has settled away, the historical `WithdrawalPendingCreated` for that id. `WithdrawalClaimed` is not an identity source — it records the payout, not the registration, and the pending entry is deleted on settlement. A slot whose tuple differs produces a different identity and its own free nullifier; it is not an already-claimed success.

### Payout is a separate transaction

`claimPendingWithdrawal` reverts `PendingWithdrawalNotFound` when no pending entry exists (`amount == 0`, which also covers an already settled identity), `PendingClaimsPaused` when the effective flags include pending-claim pause, and `PendingWithdrawalNotClaimable` before `claimableAt`. `forceClaimWithdrawal` also enforces the time check and reverts `UnauthorizedWithdrawalForceClaimExecutor` for any other caller. Ordinary claims additionally reject governed entries with `WithdrawalGovernanceRequired`. Both calls also revert `UnknownWithdrawalSourceRoot(withdrawalId, sourceRoot)` unless the entry's recorded source root is still in the StateManager's `knownWithdrawalSubtreeRoots` registry; validity follows the current registry, so a re-added root is valid again, a revoked root leaves only cancellation, and entries registered before the source-root field existed read zero and fail closed. Neither call consumes a nullifier; registration already did. A registration that was skipped, including reasons 6, 7, 9, and 10, leaves the nullifier free, so the same withdrawal can be registered again once the condition clears. Pause flags are `PAUSE_DEPOSITS` (bit 0), `PAUSE_WITHDRAWAL_REGISTRATION` (bit 1), and `PAUSE_PENDING_CLAIMS` (bit 2), combined as `global | per-token`.

`cancelPendingWithdrawal(bytes32)` lets a Bridge admin cancel an unpaid pending withdrawal without a guardian role or pause prerequisite. It deletes the pending entry and settlement tier, frees the nullifier, subtracts the amount from the token's cumulative withdrawal total, and emits `WithdrawalPendingCancelled`; it transfers no tokens and changes no roots. Missing or already-paid entries revert `PendingWithdrawalNotFound`. The pending entry stores the source root of the proof that registered it, and settlement and cancellation delete the whole record. Cancellation alone does not invalidate the proof: revoke abandoned withdrawal roots before allowing registration again after a rollback.

`PsyAddressesProvider.setZkVerifier(address)` is owner-only, rejects the zero address, and emits `AddressSet` for `ZK_VERIFIER_ID`. `StateManager.finalize` resolves this address on every call, so the next finalize uses the replacement verifier without a StateManager upgrade. Reward-claim and withdrawal-claim verifier setters are unchanged.


## Upgrade / Rescue Runbook

Upgradeable production contracts use OpenZeppelin v5 transparent proxies owned by `DefaultProxyAdmin`.

Upgradeable deployment names:
- `PsyAddressesProvider`
- `PsyACLManager`
- `StateManager`
- `Bridge`
- `Router`
- `ERC20Gateway`
- `ETHGateway`
- `TokenFaucetManager`

Governance executor:
- `ExecutorWithTimelock` is deployed by `deploy/007c_deploy_timelock.ts`.
- `deploy/007d_grant_timelock_roles.ts` grants `DEFAULT_ADMIN_ROLE`, `BRIDGE_ADMIN_ROLE`, `ROUTER_ADMIN_ROLE`, and `STATE_MANAGER_ADMIN_ROLE` to the timelock when `GRANT_TIMELOCK_ROLES=1`.
- `deploy/007e_transfer_proxy_admin_to_timelock.ts` transfers `DefaultProxyAdmin` ownership to the timelock when `TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1`.
- Set `TIMELOCK_ADMIN` to the multisig address, or it defaults to `cfg.owner`.
- `PROPOSER_ROLE` is an operational bot role, intentionally separate from governance: it is held by a
  dedicated proposer address that must be distinct from the deployer/admin, the Governance Safe, and
  the timelock. It is not migrated or revoked during the governance cutover and survives cutovers by design.

Notes:
- Deploying `ExecutorWithTimelock` alone does not hand over every permission. By default, `cfg.admin` remains the ACL default admin and the `DefaultProxyAdmin` owner.
- `GRANT_TIMELOCK_ROLES=1` grants ACL administration, Bridge administration, Router administration, and StateManager administration to the timelock. It does not transfer proxy-upgrade ownership; that remains a separate cutover.
- `TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1` is the separate cutover step for proxy upgrades. Without it, implementation upgrades can still be executed directly by the current `DefaultProxyAdmin` owner.
- `state-manager:force-set-state` and `bridge:force-set-state` require complete `EXPECTED_*` and `NEW_*` non-mapping state tuples; inputs are validated before encoding or sending a transaction.
Upgrade modes use `DRY_RUN`:
- Fork governance tests and forked upgrade scripts need a working `SEPOLIA_RPC_URL`. If the default public RPC rate-limits or returns 403, override it explicitly, for example `SEPOLIA_RPC_URL=https://sepolia.drpc.org`.
- unset: execute directly through the connected signer. This works only while `DefaultProxyAdmin` is still directly owned by that signer.
- `Run`: send the encoded transaction directly to the target contract. This also requires direct `DefaultProxyAdmin` ownership for upgrades.
- `TimeLock`: print queue/execute/cancel calldata for `ExecutorWithTimelock`.
- `Safe`: write an offline Safe proposal JSON under `deployments/<network>/safe-proposals/`.
- `SafeWithTimeLock`: write a Safe proposal that targets the timelock calldata.
- Once `TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1` has been applied, upgrades must go through `TimeLock` or `SafeWithTimeLock`.
- Mainnet cutover gate: a mainnet deployment is only considered complete when all of the following hold:
  `GRANT_TIMELOCK_ROLES=1` (ACL admin roles to the timelock), `TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1`
  (proxy-admin ownership to the timelock; the deploy script now refuses to silently skip on non-local
  networks), and `npx hardhat governance:verify-permissions --strip-admins <admin addresses> --proposer <bot>`
  passes with no violations. The verifier enforces that no stripped account holds
  BRIDGE_ADMIN/ROUTER_ADMIN/STATE_MANAGER_ADMIN/DEFAULT_ADMIN/GUARDIAN (the Governance Safe keeps
  GUARDIAN by design) and that the proposer is a configured bot address distinct from the timelock
  and the Governance Safe.

Examples:

```bash
# Activate full timelock governance for upgrade + rescue/force-set paths
GRANT_TIMELOCK_ROLES=1 \
TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1 \
npx hardhat deploy --tags timelock_proxy_admin --network sepolia

# Encode a timelock queue operation for a storage-compatible Router upgrade
DRY_RUN=TimeLock npx hardhat upgrade --contract Router --network sepolia

# Upgrade Bridge to the current in-place implementation directly on a fork/local network
DRY_RUN=Run npx hardhat upgrade --contract Bridge --network localhost
```

StateManager force state repair writes the five state fields and then uses named checkpoint-tree-root revocation. `forceSetState` does not discard roots and does not pause finalization or claims.

**Deployment boundary:** slots 0–7 stay compatible with the current layout, and slot 8 is unused after the clean flag is removed. Do not reserve a gap or a mirror flag. Rebuild/redeploy the local StateManager and non-upgradeable PsyToken before E2E, wire the provider consistently, and regenerate guardian authorization after deployment because it binds L1 code hashes. Do not reuse authorization from the preceding deployment.

```bash
DRY_RUN=TimeLock \
EXPECTED_LAST_FINALIZED_CHECKPOINT_ID=100187 \
EXPECTED_LAST_VERIFIED_CHECKPOINT_ROOT=0xe3f1bcc23eff84f7a1d2f71c91cfdcc5cd3947380970cbd49fe8663eb78e2b0a \
EXPECTED_LAST_VERIFIED_DEPOSIT_TREE_ROOT=0x2588266e5eaea8ff9867d7a36694e35c04bccc5ab36d40d565d8579beb6aff08 \
EXPECTED_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT=0x030522995310a315f591ff2e948dd628b1fa274e838eeaac00e8ec6a3cba8778 \
EXPECTED_WITHDRAWAL_SUBTREE_ROOT=0x54deb75cb039b1e82e43dff69194f26d10eae2876fb0aa33c8857a6622fda55c \
NEW_LAST_FINALIZED_CHECKPOINT_ID=100000 \
NEW_LAST_VERIFIED_CHECKPOINT_ROOT=0xe3f1bcc23eff84f7a1d2f71c91cfdcc5cd3947380970cbd49fe8663eb78e2b0a \
NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT=0x2588266e5eaea8ff9867d7a36694e35c04bccc5ab36d40d565d8579beb6aff08 \
NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT=0x030522995310a315f591ff2e948dd628b1fa274e838eeaac00e8ec6a3cba8778 \
NEW_WITHDRAWAL_SUBTREE_ROOT=0x54deb75cb039b1e82e43dff69194f26d10eae2876fb0aa33c8857a6622fda55c \
npx hardhat state-manager:force-set-state --network sepolia
```

A real force-set does not revoke mappings. Identify roots that must be discarded from retained settlement evidence (`Finalized` events and the approved rollback lineage); the contract does not enumerate them. Preserve unaffected historical roots. Do the repair in this order, with the existing Bridge pause bits only and no new phase flag: pause withdrawals (`PAUSE_DEPOSITS`, `PAUSE_WITHDRAWAL_REGISTRATION`, `PAUSE_PENDING_CLAIMS`), stop the edge processor, delete the latest block data, `forceSetState`, revoke the named roots, manually check every named root maps to zero, restart, then unpause only after that check. Encode/execute each named batch with StateManager-admin authority:

```bash
DRY_RUN=TimeLock npx hardhat state-manager:revoke-checkpoint-tree-roots --roots-json abandoned-checkpoint-roots.json --network sepolia
```

`--roots-json` accepts a file path or an inline JSON array of nonzero bytes32 hex values. `revokeCheckpointTreeRoots(bytes32[])` zeroes only the named mapping entries and accepts repeated/already-revoked roots. Split the approved list into batches that fit the network gas limit. If bridge subtree memberships are abandoned, separately encode `revokeKnownSubtreeRoots(bytes32[],bytes32[])` with the deposit and withdrawal subtree lists; it sets only those known-root entries false, is idempotent, and does not change current state fields.

```bash
DRY_RUN=TimeLock npx hardhat state-manager:revoke-known-subtree-roots --deposit-roots-json abandoned-deposit-roots.json --withdrawal-roots-json abandoned-withdrawal-roots.json --network sepolia
```

Both subtree options accept JSON files or inline arrays, including empty arrays and the zero root. **Withdrawal warning:** clearing `knownWithdrawalSubtreeRoots[root]` does not revoke the current `withdrawalSubtreeRoot` field: Bridge accepts equality with that current root independently of the mapping (`src/Bridge.sol:719-724`). Abandoning the current withdrawal root requires repairing the state field as well as revoking its historical membership. Only `batchAppend` registers a deposit subtree root, and only after its proof and public-input checks pass: the produced root at public-input offset 8, packed word-0-first (`_u32x8ToBytes32Concat`), not the low-word `depositRoot`. `finalize` reads `knownDepositSubtreeRoots[depositMerkleProof[0]]` before the Merkle and Groth16 checks and reverts `UnknownDepositSubtreeRoot` when it is false; it does not register the root. `revokeKnownSubtreeRoots` sets only the named deposit entries false.

Queue and execute all operations through the existing timelock/Safe workflow (`SafeWithTimeLock` when the Safe owns timelock administration); use a distinct `--execution-time` for repeated identical timelock operations. Verify every named checkpoint root now maps to zero, every revoked subtree membership is false, and retained roots are unchanged. That manual check is the completion signal for the operator's named list, not a flag and not proof of completeness. A no-op force-set writes nothing; force-set targets are never registered as checkpoint tree proofs.

Bridge force state repair uses `EXPECTED_BRIDGE_*` and `NEW_BRIDGE_*` values for the deposit root, proved/pending counts, and `DEPOSIT_FRONTIER_JSON`. Each frontier must be a JSON array containing exactly 32 bytes32 hex values:

```bash
DRY_RUN=TimeLock \
EXPECTED_BRIDGE_DEPOSIT_ROOT=0x... \
EXPECTED_BRIDGE_PROVED_DEPOSIT_COUNT=100 \
EXPECTED_BRIDGE_PENDING_DEPOSIT_COUNT=120 \
EXPECTED_BRIDGE_DEPOSIT_FRONTIER_JSON='["0x...", "..."]' \
NEW_BRIDGE_DEPOSIT_ROOT=0x... \
NEW_BRIDGE_PROVED_DEPOSIT_COUNT=90 \
NEW_BRIDGE_PENDING_DEPOSIT_COUNT=110 \
NEW_BRIDGE_DEPOSIT_FRONTIER_JSON='["0x...", "..."]' \
npx hardhat bridge:force-set-state --network sepolia
```

Bridge fund rescue after upgrading the in-place implementation:

```bash
# ERC20 rescue
DRY_RUN=TimeLock \
RESCUE_MODE=erc20 \
RESCUE_TOKEN=0xToken \
RESCUE_TO=0xRecipient \
RESCUE_AMOUNT=1000000000000000000 \
npx hardhat bridge:rescue --network sepolia

# Native ETH rescue
DRY_RUN=TimeLock \
RESCUE_MODE=native \
RESCUE_TO=0xRecipient \
RESCUE_AMOUNT=1000000000000000000 \
npx hardhat bridge:rescue --network sepolia

# WETH custody unwrap + native rescue
DRY_RUN=TimeLock \
RESCUE_MODE=weth-native \
RESCUE_TO=0xRecipient \
RESCUE_AMOUNT=1000000000000000000 \
npx hardhat bridge:rescue --network sepolia
```
