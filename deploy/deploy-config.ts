import fs from "fs";
import path from "path";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import type { DeployFunction } from "hardhat-deploy/types";
import { isLocalAnvilNetwork, protocolConfig, resolveProtocolNetworkName } from "../protocol-config";

export type DeployConfig = {
  admin: string;
  proposer: string;
  owner: string;
  bridgeAdmin: string;
  routerAdmin: string;
  stateManagerAdmin: string;
  rootHistorySize: number;
  l1ChainIndex: number;
  weth?: string;
  networkConfig?: string;
  bridgeAddress?: string;
  finalizeVerifier?: string;
  depositVerifier?: string;
  withdrawalVerifier?: string;
  rewardVerifier?: string;
};

const PLACEHOLDER_ADDRESSES = new Set<string>([
  "0x0000000000000000000000000000000000000001",
  "0x0000000000000000000000000000000000000002",
]);

function validateAddressLike(v: string, field: string): void {
  if (!/^0x[a-fA-F0-9]{40}$/.test(v)) {
    throw new Error(`Invalid address for ${field}: ${v}`);
  }
}

function normalize(cfg: Partial<DeployConfig>, fallback: { deployer: string; admin: string; proposer: string }): DeployConfig {
  const admin = cfg.admin ?? fallback.admin;
  const proposer = cfg.proposer ?? fallback.proposer;
  const owner = cfg.owner ?? admin;
  const bridgeAdmin = cfg.bridgeAdmin ?? admin;
  const routerAdmin = cfg.routerAdmin ?? admin;
  const stateManagerAdmin = cfg.stateManagerAdmin ?? admin;
  const rootHistorySize = cfg.rootHistorySize ?? 256;
  const l1ChainIndex = cfg.l1ChainIndex ?? 0;

  validateAddressLike(admin, "admin");
  validateAddressLike(proposer, "proposer");
  validateAddressLike(owner, "owner");
  validateAddressLike(bridgeAdmin, "bridgeAdmin");
  validateAddressLike(routerAdmin, "routerAdmin");
  validateAddressLike(stateManagerAdmin, "stateManagerAdmin");

  if (cfg.weth) validateAddressLike(cfg.weth, "weth");
  if (cfg.bridgeAddress) validateAddressLike(cfg.bridgeAddress, "bridgeAddress");
  for (const field of (["finalizeVerifier", "depositVerifier", "withdrawalVerifier", "rewardVerifier"] as const)) {
    if (cfg[field]) validateAddressLike(cfg[field], field);
  }

  return {
    admin,
    proposer,
    owner,
    bridgeAdmin,
    routerAdmin,
    stateManagerAdmin,
    rootHistorySize,
    l1ChainIndex,
    weth: cfg.weth,
    networkConfig: cfg.networkConfig,
    bridgeAddress: cfg.bridgeAddress,
    finalizeVerifier: cfg.finalizeVerifier,
    depositVerifier: cfg.depositVerifier,
    withdrawalVerifier: cfg.withdrawalVerifier,
    rewardVerifier: cfg.rewardVerifier,
  };
}

export async function loadDeployConfig(hre: HardhatRuntimeEnvironment): Promise<DeployConfig> {
  const { getNamedAccounts, network } = hre;
  const { deployer, admin, proposer } = await getNamedAccounts();
  const fallback = { deployer, admin, proposer };
  const deployingFromKeystore =
    process.env.PSY_INTERNAL_DEPLOY_FROM_KEYSTORE === "1" || !!process.env.PSY_INTERNAL_DEPLOY_PRIVATE_KEY;

  let expectedL1ChainId: number | undefined;
  let expectedL1ChainIndex: number | undefined;
  try {
    const protocolNetwork = resolveProtocolNetworkName(network.name);
    const protocolChain = protocolConfig.chains[protocolNetwork];
    expectedL1ChainId = protocolChain.l1ChainId;
    expectedL1ChainIndex = protocolChain.l1ChainIndex;
  } catch (err) {
    if (!(err instanceof Error && err.message.startsWith("Unsupported protocol network:"))) {
      throw err;
    }
  }

  if (expectedL1ChainId != null) {
    const connectedChainId = Number(await hre.getChainId());
    if (connectedChainId !== expectedL1ChainId) {
      throw new Error(
        `Refusing deployment to ${network.name}: RPC eth_chainId=${connectedChainId} ` +
          `does not match protocol-config l1ChainId=${expectedL1ChainId}`
      );
    }
  }

  const cfgPath = path.join(hre.config.paths.root, "config", `${network.name}.json`);
  const parsed = fs.existsSync(cfgPath)
    ? JSON.parse(fs.readFileSync(cfgPath, "utf8")) as Partial<DeployConfig>
    : {};
  if (parsed.l1ChainIndex == null && expectedL1ChainIndex != null) {
    parsed.l1ChainIndex = expectedL1ChainIndex;
  }
  const effectiveParsed: Partial<DeployConfig> = deployingFromKeystore
    ? {
      ...parsed,
      admin: deployer,
      proposer: deployer,
      owner: deployer,
      bridgeAdmin: deployer,
      routerAdmin: deployer,
      stateManagerAdmin: deployer,
    }
    : parsed;

  const cfg = normalize(effectiveParsed, fallback);
  if (expectedL1ChainIndex != null) {
    if (cfg.l1ChainIndex !== expectedL1ChainIndex) {
      throw new Error(
        `Invalid deploy config for ${network.name}: config/${network.name}.json l1ChainIndex=${cfg.l1ChainIndex} ` +
          `does not match protocol-config l1ChainIndex=${expectedL1ChainIndex}`
      );
    }
  }

  if (!isLocalAnvilNetwork(network.name)) {
    const check = [cfg.admin, cfg.proposer, cfg.bridgeAdmin, cfg.routerAdmin, cfg.stateManagerAdmin];
    if (check.some((v) => PLACEHOLDER_ADDRESSES.has(v.toLowerCase()))) {
      throw new Error(
        `Invalid deploy config for ${network.name}: governance/role addresses cannot be placeholder addresses. ` +
          `Please set real multisig/timelock-controlled addresses in config/${network.name}.json`
      );
    }
  }

  return cfg;
}

export type AtomicDeployConfig = DeployConfig & {
  networkConfig: string;
  bridgeAddress: string;
  finalizeVerifier: string;
  depositVerifier: string;
  withdrawalVerifier: string;
  rewardVerifier: string;
};

// Bridge and StateManager bind each other through the provider during initialize, so the
// reviewed network config must already name both precommitted proxy addresses and the four
// circuit-specific verifier addresses exported from the matching setup cohorts.
export function requireAtomicDeployConfig(cfg: DeployConfig): AtomicDeployConfig {
  const { networkConfig, bridgeAddress, finalizeVerifier, depositVerifier, withdrawalVerifier, rewardVerifier } = cfg;
  if (!networkConfig || !bridgeAddress || !finalizeVerifier || !depositVerifier || !withdrawalVerifier || !rewardVerifier) {
    throw new Error(
      "Atomic bridge deployment requires reviewed networkConfig bytes, the precommitted bridgeAddress, and " +
        "finalize/deposit/withdrawal/reward verifier addresses in config/<network>.json; " +
        "setup export and deployment remain separate authorization gates."
    );
  }
  return { ...cfg, networkConfig, bridgeAddress, finalizeVerifier, depositVerifier, withdrawalVerifier, rewardVerifier };
}

const func: DeployFunction = async function () {};
func.tags = [];
func.skip = async () => true;
export default func;
