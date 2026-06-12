import dotenv from "dotenv";

dotenv.config();

export const ETHERSCAN_KEY = process.env.ETHERSCAN_KEY || "";
export const SEPOLIA_ETHERSCAN_KEY =
  process.env.SEPOLIA_ETHERSCAN_KEY || ETHERSCAN_KEY;
export const MAINNET_ETHERSCAN_KEY =
  process.env.MAINNET_ETHERSCAN_KEY || ETHERSCAN_KEY;

export const ETHERSCAN_VERIFICATION =
  process.env.ETHERSCAN_VERIFICATION === "true";
export const ETHERSCAN_VERIFICATION_PROVIDER =
  process.env.ETHERSCAN_VERIFICATION_PROVIDER || "hardhat";
export const ETHERSCAN_VERIFICATION_MAX_RETRIES = parseInt(
  process.env.ETHERSCAN_VERIFICATION_MAX_RETRIES || "3"
);

export const COMPILER_VERSION = "0.8.24";
export const COMPILER_OPTIMIZER_RUNS = 200;

// Explorer API URLs per network
export const ETHERSCAN_APIS: Record<string, string> = {
  hardhat: "http://localhost:4000/api",
  localhost: "http://localhost:4000/api",
  sepolia: "https://api-sepolia.etherscan.io/api",
  ethereum: "https://api.etherscan.io/api",
};

// Block explorer URLs per network
export const BROWSER_URLS: Record<string, string> = {
  hardhat: "http://localhost:4000",
  localhost: "http://localhost:4000",
  sepolia: "https://sepolia.etherscan.io",
  ethereum: "https://etherscan.io",
};
