import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { log } = deployments;
  const { deployer } = await getNamedAccounts();

  log(`Running 001b_deploy_multicall3 on ${network.name}`);

  await deploy(hre, "Multicall3", {
    from: deployer,
    args: [],
    log: true,
  });
};

export default func;
func.tags = ["multicall3"];

