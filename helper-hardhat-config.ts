import { HardhatNetworkUserConfig } from "hardhat/types";
import { protocolConfig } from "./protocol-config";

export type NetworkName =
  | "hardhat"
  | "localhost"
  | "sepolia"
  | "ethereum"

export type NetworkConfigItem = {
  chainId: number;
  rpcUrl: string;
  weth?: string;
};

export const networkConfig: Record<NetworkName, NetworkConfigItem> = {
  hardhat: {
    chainId: protocolConfig.chains.localhost.l1ChainId,
    rpcUrl: protocolConfig.chains.localhost.defaultRpcUrl,
  },
  localhost: {
    chainId: protocolConfig.chains.localhost.l1ChainId,
    rpcUrl: process.env.LOCALHOST_RPC_URL || protocolConfig.chains.localhost.defaultRpcUrl,
  },
  sepolia: {
    chainId: protocolConfig.chains.sepolia.l1ChainId,
    rpcUrl: process.env.SEPOLIA_RPC_URL || protocolConfig.chains.sepolia.defaultRpcUrl,
  },
  ethereum: {
    chainId: protocolConfig.chains.ethereum.l1ChainId,
    rpcUrl: process.env.ETH_RPC_URL || protocolConfig.chains.ethereum.defaultRpcUrl,
    weth: process.env.ETH_WETH,
  },
};

function getInternalDeployPrivateKey(): string | undefined {
  const directPrivateKey = process.env.PSY_RELAYER_PRIVKEY || process.env.PRIVATE_KEY;
  const internalPrivateKey = process.env.PSY_INTERNAL_DEPLOY_PRIVATE_KEY;

  if (process.env.PSY_INTERNAL_DEPLOY_FROM_KEYSTORE === "1" && !internalPrivateKey) {
    throw new Error("PSY_INTERNAL_DEPLOY_FROM_KEYSTORE=1 requires PSY_INTERNAL_DEPLOY_PRIVATE_KEY to be set.");
  }

  return internalPrivateKey || directPrivateKey;
}

function isForkMode(): boolean {
  const raw = (process.env.VITE_FORK ?? "").trim().toLowerCase()
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on"
}

export function mkNetworkCfg(name: NetworkName): HardhatNetworkUserConfig | undefined {
  const cfg = networkConfig[name];
  if (!cfg) return undefined;
  const privateKey = getInternalDeployPrivateKey();
  const chainId = (isForkMode() && (name === "sepolia" || name === "ethereum"))
    ? protocolConfig.chains.localhost.l1ChainId
    : cfg.chainId;
  const base: HardhatNetworkUserConfig = {
    url: cfg.rpcUrl,
    chainId,
  };
  if (privateKey) {
    base.accounts = [privateKey];
  }
  return base;
}
