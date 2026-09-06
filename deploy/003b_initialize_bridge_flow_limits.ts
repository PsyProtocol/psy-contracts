import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { ethers } from "hardhat";
import { isLocalAnvilNetwork, protocolConfig, resolveProtocolNetworkName } from "../protocol-config";
import { loadDeployConfig } from "./deploy-config";
import { loadBridgeFlowLimitManifest, tokenSetHash, type FlowLimitConfig } from "../scripts/upgrade/bridge";

function localFlowLimitConfig(): FlowLimitConfig {
  return {
    minDepositAmount: "1",
    depositCap: "10000000000000000000000000",
    smallWithdrawalMax: "10000000000000000000",
    mediumWithdrawalMax: "100000000000000000000",
    totalWithdrawalCap: "1000000000000000000000",
    smallWithdrawalDelay: "0",
    mediumWithdrawalDelay: "0",
    largeWithdrawalDelay: "0",
    configured: true,
  };
}

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { execute, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  if (network.name === "hardhat" && process.env.PSY_SKIP_BRIDGE_FLOW_LIMITS === "1") {
    log("Skipping Bridge flow-limit initialization for an explicit hardhat test fixture");
    return;
  }

  const configPath = process.env.BRIDGE_FLOW_LIMITS_FILE;
  let tokens: string[];
  let configs: FlowLimitConfig[];
  let historicalWithdrawalTotals: string[];

  const timelock = await deployments.get("ExecutorWithTimelock");
  if (configPath) {
    const manifest = loadBridgeFlowLimitManifest(configPath);
    tokens = manifest.tokens;
    configs = manifest.configs;
    historicalWithdrawalTotals = manifest.historicalWithdrawalTotals;
  } else if (isLocalAnvilNetwork(network.name)) {
    const protocolNetwork = resolveProtocolNetworkName(network.name);
    const deployedTokens: string[] = [];
    for (const token of Object.values(protocolConfig.tokens)) {
      const deployment = token.deployments[protocolNetwork];
      if (deployment?.l1Address) {
        deployedTokens.push(ethers.utils.getAddress(deployment.l1Address));
      } else if (deployment?.deployName) {
        deployedTokens.push((await deployments.get(deployment.deployName)).address);
      }
    }
    tokens = [ethers.constants.AddressZero, ...deployedTokens];
    configs = tokens.map(() => localFlowLimitConfig());
    historicalWithdrawalTotals = tokens.map(() => "0");
  } else {
    throw new Error("BRIDGE_FLOW_LIMITS_FILE is required for a non-local Bridge deployment");
  }
  await execute(
    "Bridge",
    { from: cfg.admin || deployer, log: true },
    "initializeFlowLimits",
    tokens,
    configs,
  );
  await execute(
    "Bridge",
    { from: cfg.admin || deployer, log: true },
    "initializeWithdrawalTotals",
    tokens,
    configs,
    historicalWithdrawalTotals,
    tokenSetHash(tokens),
    timelock.address,
  );
};

export default func;
func.tags = ["bridge_flow_limits"];
func.dependencies = ["bridge", "gateways", "timelock"];
