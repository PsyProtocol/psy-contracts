import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, network } = hre;
  const { log } = deployments;

  // Only applies to local anvil (localhost network)
  if (network.name !== "localhost") {
    log("skipping anvil interval mining setup for non-local network");
    return;
  }

  try {
    await hre.ethers.provider.send("anvil_setIntervalMining", [1]);
    log("set anvil interval mining to 1 second");
  } catch (e) {
    log(`warning: failed to set anvil interval mining: ${e}`);
  }
};

export default func;
func.tags = ["anvil_interval_mining"];
func.dependencies = ["export_deployed_contracts"];
func.skip = async (hre: HardhatRuntimeEnvironment) =>
  hre.network.name !== "localhost";
