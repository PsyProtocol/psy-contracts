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
  ETHERSCAN_KEY,
  SEPOLIA_ETHERSCAN_KEY,
  MAINNET_ETHERSCAN_KEY,
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
    ["sepolia", mkNetworkCfg("sepolia")],
    ["ethereum", mkNetworkCfg("ethereum")],
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
    },
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
