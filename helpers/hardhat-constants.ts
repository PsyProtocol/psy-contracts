import dotenv from "dotenv";

dotenv.config();

export const ETHERSCAN_KEY = process.env.ETHERSCAN_KEY || process.env.ETHERSCAN_API_KEY || "";
export const SEPOLIA_ETHERSCAN_KEY =
  process.env.SEPOLIA_ETHERSCAN_KEY || ETHERSCAN_KEY;
export const MAINNET_ETHERSCAN_KEY =
  process.env.MAINNET_ETHERSCAN_KEY || ETHERSCAN_KEY;
export const BSC_ETHERSCAN_KEY =
  process.env.BSC_ETHERSCAN_KEY || process.env.BSCSCAN_API_KEY || ETHERSCAN_KEY;
export const BASE_ETHERSCAN_KEY =
  process.env.BASE_ETHERSCAN_KEY || process.env.BASESCAN_API_KEY || ETHERSCAN_KEY;

export const ETHERSCAN_VERIFICATION =
  process.env.ETHERSCAN_VERIFICATION === "true";
export const ETHERSCAN_VERIFICATION_PROVIDER =
  process.env.ETHERSCAN_VERIFICATION_PROVIDER || "foundry";
export const ETHERSCAN_VERIFICATION_MAX_RETRIES = parseInt(
  process.env.ETHERSCAN_VERIFICATION_MAX_RETRIES || "3"
);


export enum DryRunExecutor {
  TimeLock = "TimeLock",
  Safe = "Safe",
  SafeWithTimeLock = "SafeWithTimeLock",
  Run = "Run",
  None = "",
}

export enum TimeLockOperation {
  Queue = "Queue",
  Execute = "Execute",
  Cancel = "Cancel",
}

export const DRY_RUN = (process.env.DRY_RUN || "") as DryRunExecutor;
export const TIMELOCK_OPERATION =
  (process.env.TIMELOCK_OPERATION || TimeLockOperation.Queue) as TimeLockOperation;
export const MULTI_SIG = process.env.MULTI_SIG || "";
export const SAFE_TX_SERVICE_URL = process.env.SAFE_TX_SERVICE_URL || "";
export const TIMELOCK_ETA_BUFFER_SECONDS = parseInt(process.env.TIMELOCK_ETA_BUFFER_SECONDS || "60", 10);
export const GLOBAL_OVERRIDES = {
  gasLimit: process.env.TX_GAS_LIMIT ? Number(process.env.TX_GAS_LIMIT) : undefined,
};
export const COMPILER_VERSION = "0.8.24";
export const COMPILER_OPTIMIZER_RUNS = 200;

// Explorer API URLs per network
export const ETHERSCAN_APIS: Record<string, string> = {
  hardhat: "http://localhost:4000/api",
  localhost: "http://localhost:4000/api",
  localhostBsc: "http://localhost:4000/api",
  localhostBase: "http://localhost:4000/api",
  sepolia: "https://api-sepolia.etherscan.io/api",
  bscTestnet: "https://api-testnet.bscscan.com/api",
  baseSepolia: "https://api-sepolia.basescan.org/api",
  ethereum: "https://api.etherscan.io/api",
  bsc: "https://api.bscscan.com/api",
  base: "https://api.basescan.org/api",
};

// Block explorer URLs per network
export const BROWSER_URLS: Record<string, string> = {
  hardhat: "http://localhost:4000",
  localhost: "http://localhost:4000",
  localhostBsc: "http://localhost:4000",
  localhostBase: "http://localhost:4000",
  sepolia: "https://sepolia.etherscan.io",
  bscTestnet: "https://testnet.bscscan.com",
  baseSepolia: "https://sepolia-explorer.base.org",
  ethereum: "https://etherscan.io",
  bsc: "https://bscscan.com",
  base: "https://basescan.org",
};
