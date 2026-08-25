import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { loadBridgeFlowLimitManifest } from "../scripts/upgrade/bridge";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { execute, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const configPath = process.env.BRIDGE_FLOW_LIMITS_FILE;

  if (!configPath) {
    if (network.name === "hardhat" || network.name === "localhost") {
      log("Skipping Bridge flow-limit initialization on local network; BRIDGE_FLOW_LIMITS_FILE is unset");
      return;
    }
    throw new Error("BRIDGE_FLOW_LIMITS_FILE is required for a non-local Bridge deployment");
  }

  const manifest = loadBridgeFlowLimitManifest(configPath);
  await execute(
    "Bridge",
    { from: cfg.admin || deployer, log: true },
    "initializeFlowLimits",
    manifest.tokens,
    manifest.configs,
  );
};

export default func;
func.tags = ["bridge_flow_limits"];
func.dependencies = ["bridge"];
