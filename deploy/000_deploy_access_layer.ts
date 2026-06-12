import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { getNamedAccounts, network, deployments } = hre;
  const { log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);

  log("Running 000_deploy_access_layer on " + network.name);

  await deploy(hre, "PsyAddressesProvider", {
    from: deployer,
    log: true,
    args: [],
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [cfg.admin],
        },
      },
    },
  });

  await deploy(hre, "PsyACLManager", {
    from: deployer,
    log: true,
    args: [],
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [cfg.admin, cfg.bridgeAdmin, cfg.routerAdmin, cfg.stateManagerAdmin, cfg.proposer],
        },
      },
    },
  });
};

export default func;
func.tags = ["access"];
