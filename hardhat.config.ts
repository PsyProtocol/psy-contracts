import "@nomicfoundation/hardhat-toolbox";
import "hardhat-deploy";
import * as dotenv from "dotenv";
import fs from "fs";
import path from "path";
import { HardhatUserConfig, subtask } from "hardhat/config";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names";
import { mkNetworkCfg, type NetworkName, networkConfig } from "./helper-hardhat-config";
import { protocolConfig } from "./protocol-config";
import {
  SEPOLIA_ETHERSCAN_KEY,
  MAINNET_ETHERSCAN_KEY,
  BSC_ETHERSCAN_KEY,
  BASE_ETHERSCAN_KEY,
} from "./helpers/hardhat-constants";
import "./tasks/verify";
import "./tasks/upgrade";
import "./tasks/governance";

dotenv.config();

function listSolidityFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) {
    return [];
  }
  const files: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listSolidityFiles(fullPath));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".sol")) {
      files.push(fullPath);
    }
  }
  return files;
}

subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, hre, runSuper) => {
  const sources = await runSuper();
  const fixtures = listSolidityFiles(
    path.join(hre.config.paths.root, "test", "fixtures", "contracts")
  );
  return [...sources, ...fixtures];
});

const optNetworks = Object.fromEntries(
  [
    ["localhost", mkNetworkCfg("localhost")],
    ["localhostBsc", mkNetworkCfg("localhostBsc")],
    ["localhostBase", mkNetworkCfg("localhostBase")],
    ["sepolia", mkNetworkCfg("sepolia")],
    ["bscTestnet", mkNetworkCfg("bscTestnet")],
    ["baseSepolia", mkNetworkCfg("baseSepolia")],
    ["ethereum", mkNetworkCfg("ethereum")],
    ["bsc", mkNetworkCfg("bsc")],
    ["base", mkNetworkCfg("base")],
  ].filter(([, cfg]) => cfg !== undefined)
);

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      evmVersion: "paris",
    },
  },
  namedAccounts: {
    deployer: {
      default: 0,
    },
    admin: {
      default: 0,
    },
    proposer: {
      default: 0,
    },
  },
  networks: {
    hardhat: {
      chainId: protocolConfig.chains.localhost.l1ChainId,
    },
    ...(optNetworks as Record<string, unknown>),
  },
  etherscan: {
    apiKey: {
      sepolia: SEPOLIA_ETHERSCAN_KEY,
      ethereum: MAINNET_ETHERSCAN_KEY,
      bscTestnet: BSC_ETHERSCAN_KEY,
      bsc: BSC_ETHERSCAN_KEY,
      baseSepolia: BASE_ETHERSCAN_KEY,
      base: BASE_ETHERSCAN_KEY,
    },
    customChains: [
      {
        network: "bscTestnet",
        chainId: protocolConfig.chains.bscTestnet.l1ChainId,
        urls: {
          apiURL: "https://api-testnet.bscscan.com/api",
          browserURL: protocolConfig.chains.bscTestnet.defaultExplorerUrl!,
        },
      },
      {
        network: "bsc",
        chainId: protocolConfig.chains.bsc.l1ChainId,
        urls: {
          apiURL: "https://api.bscscan.com/api",
          browserURL: protocolConfig.chains.bsc.defaultExplorerUrl!,
        },
      },
      {
        network: "baseSepolia",
        chainId: protocolConfig.chains.baseSepolia.l1ChainId,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: protocolConfig.chains.baseSepolia.defaultExplorerUrl!,
        },
      },
      {
        network: "base",
        chainId: protocolConfig.chains.base.l1ChainId,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: protocolConfig.chains.base.defaultExplorerUrl!,
        },
      },
    ],
  },
  paths: {
    sources: "./src",
    tests: "./test/hardhat",
    cache: "./cache/hardhat",
    artifacts: "./artifacts/hardhat",
    deploy: "./deploy",
    deployments: "./deployments",
  },
};

export default config;
