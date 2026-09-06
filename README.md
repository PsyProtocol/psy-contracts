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

Direct deploy private keys are intentionally disabled. Use `scripts/deploy-with-keystore.mjs` or the `deploy:keystore:*` npm scripts.

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

# Encode a timelock queue operation for the in-place StateManager implementation
DRY_RUN=TimeLock npx hardhat upgrade --contract StateManager --network sepolia

# Upgrade Bridge to the current in-place implementation directly on a fork/local network
DRY_RUN=Run npx hardhat upgrade --contract Bridge --network localhost

# Encode all known proxy upgrades
DRY_RUN=TimeLock npx hardhat upgrade:all --network sepolia
```

StateManager force state repair after upgrading the in-place implementation:

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
