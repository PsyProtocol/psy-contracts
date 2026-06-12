import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { get, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);

  log("Running 003_deploy_bridge on " + network.name);
  const provider = await get("PsyAddressesProvider");
  const withdrawalClaimVerifier = await get("WithdrawalClaimVerifier");
  const depositBatchVerifier = await get("DepositBatchVerifier");

  await deploy(hre, "Bridge", {
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
            depositBatchVerifier.address,
            withdrawalClaimVerifier.address,
          ],
        },
      },
    },
  });
};

export default func;
func.tags = ["bridge"];
func.dependencies = ["access", "verifier"];
