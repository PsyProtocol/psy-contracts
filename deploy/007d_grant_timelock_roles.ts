import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { execute, get, read, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const txFrom = cfg.admin || deployer;

  if (process.env.GRANT_TIMELOCK_ROLES !== "1") {
    log("Skipping 007d_grant_timelock_roles; set GRANT_TIMELOCK_ROLES=1 to enable");
    return;
  }

  const timelock = await get("ExecutorWithTimelock");
  await get("PsyACLManager");
  log(`Running 007d_grant_timelock_roles -> ${timelock.address}`);

  const roles = [
    await read("PsyACLManager", "BRIDGE_ADMIN_ROLE") as string,
    await read("PsyACLManager", "STATE_MANAGER_ADMIN_ROLE") as string,
  ];

  for (const role of roles) {
    const hasRole = await read("PsyACLManager", "hasRole", role, timelock.address) as boolean;
    if (!hasRole) {
      await execute("PsyACLManager", { from: txFrom, log: true }, "grantRole", role, timelock.address);
    }
  }
};

export default func;
func.tags = ["timelock_roles"];
func.dependencies = ["timelock"];
