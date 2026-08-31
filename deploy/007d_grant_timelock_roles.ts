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

  if (process.env.REVOKE_LEGACY_ADMIN_ROLES === "1") {
    const legacyAssignments = [
      [await read("PsyACLManager", "BRIDGE_ADMIN_ROLE") as string, cfg.bridgeAdmin],
      [await read("PsyACLManager", "ROUTER_ADMIN_ROLE") as string, cfg.routerAdmin],
      [await read("PsyACLManager", "STATE_MANAGER_ADMIN_ROLE") as string, cfg.stateManagerAdmin],
      // DEFAULT_ADMIN_ROLE must be revoked last because it administers all roles.
      [await read("PsyACLManager", "DEFAULT_ADMIN_ROLE") as string, cfg.admin],
    ] as const;
    for (const [role, account] of legacyAssignments) {
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
