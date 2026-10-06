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

  log("Running 002_deploy_state_manager on " + network.name);
  const provider = await get("PsyAddressesProvider");

  // StateManager binds the Bridge address from the provider during initialize, so the reviewed
  // precommitted Bridge proxy address must be registered before the atomic proxy initialization.
  const bridgeId = (await read("PsyAddressesProvider", "BRIDGE_ID")) as string;
  const currentBridge = (await read("PsyAddressesProvider", "getAddress", bridgeId)) as string;
  if (currentBridge.toLowerCase() !== cfg.bridgeAddress.toLowerCase()) {
    await execute("PsyAddressesProvider", { from: txFrom, log: true }, "setAddress", bridgeId, cfg.bridgeAddress);
  }

  await deploy(hre, "StateManager", {
    from: deployer,
    log: true,
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [
            cfg.admin,
            provider.address,
            cfg.l1ChainIndex,
            cfg.networkConfig,
            cfg.finalizeVerifier,
            cfg.depositVerifier,
            cfg.withdrawalVerifier,
            cfg.rewardVerifier,
          ],
        },
      },
    },
  });
};

export default func;
func.tags = ["state_manager"];
func.dependencies = ["access"];
