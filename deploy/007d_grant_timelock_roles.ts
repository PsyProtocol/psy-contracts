import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const LOCAL_NETWORKS = new Set(["localhost", "hardhat"]);
  if (process.env.GRANT_TIMELOCK_ROLES !== "1") {
    hre.deployments.log("Skipping 007d_grant_timelock_roles; set GRANT_TIMELOCK_ROLES=1 to enable");
    return;
  }
  if (!LOCAL_NETWORKS.has(hre.network.name) && process.env.TRANSFER_PROXY_ADMIN_TO_TIMELOCK !== "1") {
    throw new Error(
      "007d_grant_timelock_roles is part of the mainnet governance cutover and would partially execute it: " +
        "set TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1 so 007e transfers DefaultProxyAdmin in the same run, " +
        "or run on a local network"
    );
  }
  const { deployments, getNamedAccounts } = hre;
  const { execute, get, read, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const txFrom = cfg.admin || deployer;


  const timelock = await get("ExecutorWithTimelock");
  await get("PsyACLManager");
  const governanceSafe = await read("ExecutorWithTimelock", "getAdmin") as string;
  log(`Running 007d_grant_timelock_roles -> ${timelock.address}`);

  const roles = [
    await read("PsyACLManager", "DEFAULT_ADMIN_ROLE") as string,
    await read("PsyACLManager", "BRIDGE_ADMIN_ROLE") as string,
    await read("PsyACLManager", "ROUTER_ADMIN_ROLE") as string,
    await read("PsyACLManager", "STATE_MANAGER_ADMIN_ROLE") as string,
  ];

  for (const role of roles) {
    const hasRole = await read("PsyACLManager", "hasRole", role, timelock.address) as boolean;
    if (!hasRole) {
      await execute("PsyACLManager", { from: txFrom, log: true }, "grantRole", role, timelock.address);
    }
  }

  const guardianRole = await read("PsyACLManager", "GUARDIAN_ROLE") as string;
  const safeIsGuardian = await read(
    "PsyACLManager",
    "hasRole",
    guardianRole,
    governanceSafe,
  ) as boolean;
  if (!safeIsGuardian) {
    await execute(
      "PsyACLManager",
      { from: txFrom, log: true },
      "grantRole",
      guardianRole,
      governanceSafe,
    );
  }

  if (process.env.REVOKE_REPLACED_ADMIN_ROLES === "1") {
    const replacedAssignments = [
      [await read("PsyACLManager", "BRIDGE_ADMIN_ROLE") as string, cfg.bridgeAdmin],
      [await read("PsyACLManager", "ROUTER_ADMIN_ROLE") as string, cfg.routerAdmin],
      [await read("PsyACLManager", "STATE_MANAGER_ADMIN_ROLE") as string, cfg.stateManagerAdmin],
      // DEFAULT_ADMIN_ROLE must be revoked last because it administers all roles.
      [await read("PsyACLManager", "DEFAULT_ADMIN_ROLE") as string, cfg.admin],
    ] as const;
    for (const [role, account] of replacedAssignments) {
      if (account.toLowerCase() === timelock.address.toLowerCase()) continue;
      const hasRole = await read("PsyACLManager", "hasRole", role, account) as boolean;
      if (hasRole) {
        await execute("PsyACLManager", { from: txFrom, log: true }, "revokeRole", role, account);
      }
    }
  }
};

export default func;
func.tags = ["timelock_roles"];
func.dependencies = ["timelock"];
