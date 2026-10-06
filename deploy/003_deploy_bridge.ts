import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig, requireAtomicDeployConfig } from "./deploy-config";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { get, read, execute, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = requireAtomicDeployConfig(await loadDeployConfig(hre));
  const txFrom = cfg.admin || deployer;

  log("Running 003_deploy_bridge on " + network.name);
  const provider = await get("PsyAddressesProvider");
  const stateManager = await get("StateManager");

  // Bridge binds the StateManager address from the provider during initialize.
  const stateManagerId = (await read("PsyAddressesProvider", "STATE_MANAGER_ID")) as string;
  const currentStateManager = (await read("PsyAddressesProvider", "getAddress", stateManagerId)) as string;
  if (currentStateManager.toLowerCase() !== stateManager.address.toLowerCase()) {
    await execute("PsyAddressesProvider", { from: txFrom, log: true }, "setAddress", stateManagerId, stateManager.address);
  }

  await deploy(hre, "Bridge", {
    from: deployer,
    log: true,
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [cfg.admin, provider.address, cfg.networkConfig, cfg.l1ChainIndex],
        },
      },
    },
  });
};

export default func;
func.tags = ["bridge"];
func.dependencies = ["access", "state_manager"];
