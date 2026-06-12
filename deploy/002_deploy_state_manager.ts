import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { get, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);

  log("Running 002_deploy_state_manager on " + network.name);
  const provider = await get("PsyAddressesProvider");

  await deploy(hre, "StateManager", {
    from: deployer,
    log: true,
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [cfg.admin, provider.address, cfg.l1ChainIndex],
        },
      },
    },
  });
};

export default func;
func.tags = ["state_manager"];
func.dependencies = ["access"];
