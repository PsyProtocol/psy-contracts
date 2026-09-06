import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { isLocalAnvilNetwork } from "../protocol-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { execute, get, read, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const txFrom = cfg.admin || deployer;

  if (process.env.TRANSFER_PROXY_ADMIN_TO_TIMELOCK !== "1") {
    if (!isLocalAnvilNetwork(network.name)) {
      throw new Error(
        "007e_transfer_proxy_admin_to_timelock is a required mainnet cutover gate: " +
          "set TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1 to transfer DefaultProxyAdmin to the timelock " +
          "and then run 'npx hardhat governance:verify-permissions' until it is all-green. " +
          "Refusing to silently skip proxy-admin cutover on " + network.name
      );
    }
    log("Skipping 007e_transfer_proxy_admin_to_timelock; set TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1 to enable");
    return;
  }

  const timelock = await get("ExecutorWithTimelock");
  await get("DefaultProxyAdmin");
  log(`Running 007e_transfer_proxy_admin_to_timelock -> ${timelock.address}`);

  const currentOwner = await read("DefaultProxyAdmin", "owner") as string;
  if (currentOwner.toLowerCase() === timelock.address.toLowerCase()) {
    log("DefaultProxyAdmin already owned by timelock");
    return;
  }

  await execute("DefaultProxyAdmin", { from: txFrom, log: true }, "transferOwnership", timelock.address);
};

export default func;
func.tags = ["timelock_proxy_admin"];
func.dependencies = ["timelock_roles"];
