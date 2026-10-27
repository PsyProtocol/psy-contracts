import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { ethers } from "hardhat";
import { isLocalAnvilNetwork, protocolConfig, resolveProtocolNetworkName } from "../protocol-config";
import { loadDeployConfig } from "./deploy-config";
import { loadBridgeFlowLimitManifest, tokenSetHash, type FlowLimitConfig } from "../scripts/upgrade/bridge";

export function localFlowLimitConfig(decimals: number): FlowLimitConfig {
  return {
    // Inclusive max fields end one smallest unit below the 50k/100k tier boundaries.
    minDepositAmount: "1",
    depositCap: ethers.utils.parseUnits("10000000", decimals).toString(),
    smallWithdrawalMax: ethers.utils.parseUnits("50000", decimals).sub(1).toString(),
    mediumWithdrawalMax: ethers.utils.parseUnits("100000", decimals).sub(1).toString(),
    totalWithdrawalCap: ethers.utils.parseUnits("1000000000000", decimals).toString(),
    smallWithdrawalDelay: "0",
    mediumWithdrawalDelay: "3600",
    largeWithdrawalDelay: "604800",
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
    tokens = [ethers.constants.AddressZero];
    const chain = protocolConfig.chains[protocolNetwork];
    configs = [localFlowLimitConfig(chain.nativeCurrency.decimals)];
    for (const token of Object.values(protocolConfig.tokens)) {
      const deployment = token.deployments[protocolNetwork];
      if (deployment?.l1Address) {
        tokens.push(ethers.utils.getAddress(deployment.l1Address));
      } else if (deployment?.deployName) {
        tokens.push((await deployments.get(deployment.deployName)).address);
      } else {
        continue;
      }
      configs.push(localFlowLimitConfig(token.decimals));
    }
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
