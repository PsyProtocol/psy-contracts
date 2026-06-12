import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { execute, get, read, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const targetOwner = cfg.owner;

  const txFrom = cfg.admin || deployer;
  log("Running 007_transfer_ownership -> " + targetOwner);

  const ownables = [
    "PsyAddressesProvider",
    "PsyACLManager",
    "StateManager",
    "Bridge",
    "Router",
    "ERC20Gateway",
    "ETHGateway",
  ];

  for (const name of ownables) {
    await get(name);
    const currentOwner = (await read(name, "owner")) as string;
    if (currentOwner.toLowerCase() !== targetOwner.toLowerCase()) {
      await execute(name, { from: txFrom, log: true }, "transferOwnership", targetOwner);
    }
  }
};

export default func;
func.tags = ["transfer_ownership"];
func.dependencies = ["wire"];
