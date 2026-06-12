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

1. **Deploy** scripts write per-contract metadata (`address`, `constructorArgs`, `libraries`) to JSON files under `deployments/<network>/`.
2. **Verify** reads those deployment files from `deployments/<network>/` and auto-detects which contracts to verify.
3. Each contract (including `_Implementation` variants; `_Proxy` contracts are skipped) is verified via:
   - **Hardhat** (default): runs `verify:verify` with automatic retries
   - **Foundry** (`ETHERSCAN_VERIFICATION_PROVIDER=foundry`): constructs a `forge verify-contract` command with ABI-encoded constructor args via `cast abi-encode`

Contract types covered:
| Type | Example | Notes |
|------|---------|-------|
| Standalone | StateManager, Bridge | Deployed and verified directly |
| Proxy | PsyAddressesProvider_Proxy | OpenZeppelin Transparent Proxy; constructor args include (impl, admin, data) |
| Implementation | PsyAddressesProvider_Implementation | Verified against the implementation constructor args only |

> Reference: paraspace-core `tasks/dev/verifyContracts.ts` → `helpers/contracts-helpers.ts:verifyContracts()`, supporting both Hardhat and Foundry modes.

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
