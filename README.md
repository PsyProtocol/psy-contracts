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
- `LOCALHOST_RPC_URL`, `SEPOLIA_RPC_URL`, or `ETH_RPC_URL`: network RPC URL
- Optional per-network WETH envs in `helper-hardhat-config.ts` (`ETH_WETH`, `ARB_WETH`, ...)

Direct deploy private keys are intentionally disabled. Use `scripts/deploy-with-keystore.mjs` or the `deploy:keystore:*` npm scripts.

### 2) Config files
- Network deploy config is loaded from `config/<network>.json`
- For non-local networks, do not use placeholder governance addresses (`0x...01`, `0x...02`)
- `admin` should be timelock/proxy-admin owner; `proposer` should be finalize operator

### 3) Local deploy
- `KEYSTORE_PATH=... WALLET_PASSWORD=... LOCALHOST_RPC_URL=http://127.0.0.1:8545 npm run deploy:keystore:localhost`

### 4) Sepolia / Ethereum deploy
- `KEYSTORE_PATH=... WALLET_PASSWORD=... SEPOLIA_RPC_URL=https://... npm run deploy:keystore:sepolia`
- `KEYSTORE_PATH=... WALLET_PASSWORD=... ETH_RPC_URL=https://... npm run deploy:keystore:ethereum`

### 5) Post-deploy sanity checks
- `StateManager.bridge == Bridge`
- `StateManager.proposer == expected proposer`
- `Router.bridge == Bridge`
- `Router.defaultERC20Gateway == ERC20Gateway`
- `Router.ethGateway == ETHGateway`
- `StateManager.zkVerifier != address(0)`

### 6) Role model
- `StateManager.appendDeposit`: only Bridge
- `StateManager.finalize`: only Proposer
- `Bridge.recordDeposit`: disabled; canonical path is Router -> Gateway -> Bridge.recordDepositFromGateway
- `Bridge.recordDepositFromGateway`: caller must match Router-resolved gateway
