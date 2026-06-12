import fs from "fs";
import path from "path";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import type { DeployFunction } from "hardhat-deploy/types";
import { protocolConfig, resolveProtocolNetworkName } from "../protocol-config";

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
  verifier?: string;
  withdrawalClaimVerifier?: string;
  depositBatchVerifier?: string;
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
  if (cfg.verifier) validateAddressLike(cfg.verifier, "verifier");
  if (cfg.withdrawalClaimVerifier) validateAddressLike(cfg.withdrawalClaimVerifier, "withdrawalClaimVerifier");
  if (cfg.depositBatchVerifier) validateAddressLike(cfg.depositBatchVerifier, "depositBatchVerifier");

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
    verifier: cfg.verifier,
    withdrawalClaimVerifier: cfg.withdrawalClaimVerifier,
    depositBatchVerifier: cfg.depositBatchVerifier,
  };
}

export async function loadDeployConfig(hre: HardhatRuntimeEnvironment): Promise<DeployConfig> {
  const { getNamedAccounts, network } = hre;
  const { deployer, admin, proposer } = await getNamedAccounts();
  const fallback = { deployer, admin, proposer };
  const deployingFromKeystore =
    process.env.PSY_INTERNAL_DEPLOY_FROM_KEYSTORE === "1" || !!process.env.PSY_INTERNAL_DEPLOY_PRIVATE_KEY;

  const cfgPath = path.join(hre.config.paths.root, "config", `${network.name}.json`);
  if (!fs.existsSync(cfgPath)) {
    return normalize({}, fallback);
  }

  const raw = fs.readFileSync(cfgPath, "utf8");
  const parsed = JSON.parse(raw) as Partial<DeployConfig>;
  if (deployingFromKeystore) {
    const keystoreDrivenCfg: Partial<DeployConfig> = {
      ...parsed,
      admin: deployer,
      proposer: deployer,
      owner: deployer,
      bridgeAdmin: deployer,
      routerAdmin: deployer,
      stateManagerAdmin: deployer,
    };
    return normalize(keystoreDrivenCfg, fallback);
  }

  const cfg = normalize(parsed, fallback);
  try {
    const protocolNetwork = resolveProtocolNetworkName(network.name);
    const expectedL1ChainIndex = protocolConfig.chains[protocolNetwork].l1ChainIndex;
    if (cfg.l1ChainIndex !== expectedL1ChainIndex) {
      throw new Error(
        `Invalid deploy config for ${network.name}: config/${network.name}.json l1ChainIndex=${cfg.l1ChainIndex} ` +
          `does not match protocol-config ${protocolNetwork}.l1ChainIndex=${expectedL1ChainIndex}`
      );
    }
  } catch (err) {
    if (err instanceof Error && err.message.startsWith("Unsupported protocol network:")) {
      // Custom/private hardhat networks may not be part of the shared protocol config.
    } else {
      throw err;
    }
  }

  if (!["hardhat", "localhost"].includes(network.name)) {
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

const func: DeployFunction = async function () {};
func.tags = [];
func.skip = async () => true;
export default func;
