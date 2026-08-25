import { Contract } from "ethers";
import { deployments, ethers } from "hardhat";
import { dryRunEncodedData, dryRunMultipleEncodedData, getDeployedContract } from "../../helpers/contracts-helpers";
import { DRY_RUN, DryRunExecutor, MULTI_SIG } from "../../helpers/hardhat-constants";

const OWNABLE_DEPLOYMENTS = [
  "PsyAddressesProvider",
  "PsyACLManager",
  "StateManager",
  "Bridge",
  "Router",
  "ERC20Gateway",
  "ETHGateway",
  "TokenFaucetManager",
  "DefaultProxyAdmin",
] as const;

export type PermissionOperation = {
  description: string;
  target: string;
  data: string;
};

type PermissionMigrationInput = {
  acl: Contract;
  timelockAddress: string;
  governanceSafe: string;
  ownables: Array<{ name: string; contract: Contract }>;
  legacyAccounts: string[];
};

async function adminRoles(acl: Contract): Promise<Array<{ name: string; role: string }>> {
  return [
    { name: "DEFAULT_ADMIN_ROLE", role: await acl.DEFAULT_ADMIN_ROLE() },
    { name: "BRIDGE_ADMIN_ROLE", role: await acl.BRIDGE_ADMIN_ROLE() },
    { name: "ROUTER_ADMIN_ROLE", role: await acl.ROUTER_ADMIN_ROLE() },
    { name: "STATE_MANAGER_ADMIN_ROLE", role: await acl.STATE_MANAGER_ADMIN_ROLE() },
  ];
}

export async function buildPermissionMigration(input: PermissionMigrationInput): Promise<PermissionOperation[]> {
  const timelock = ethers.utils.getAddress(input.timelockAddress);
  const safe = ethers.utils.getAddress(input.governanceSafe);
  const legacyAccounts = [...new Set([...input.legacyAccounts.map(ethers.utils.getAddress), safe])]
    .filter((account) => account !== timelock);
  const roles = await adminRoles(input.acl);
  const operations: PermissionOperation[] = [];
  const defaultAdminRole = roles[0].role;
  const safeIsDefaultAdmin = await input.acl.hasRole(defaultAdminRole, safe);

  for (const { name, role } of roles) {
    if (!(await input.acl.hasRole(role, timelock))) {
      operations.push({
        description: `grant ${name} to Timelock`,
        target: input.acl.address,
        data: input.acl.interface.encodeFunctionData("grantRole", [role, timelock]),
      });
    }
  }

  const guardianRole = await input.acl.GUARDIAN_ROLE();
  if (!(await input.acl.hasRole(guardianRole, safe))) {
    operations.push({
      description: "grant GUARDIAN_ROLE to Governance Safe",
      target: input.acl.address,
      data: input.acl.interface.encodeFunctionData("grantRole", [guardianRole, safe]),
    });
  }

  for (const { name, contract } of input.ownables) {
    const owner = ethers.utils.getAddress(await contract.owner());
    if (owner !== timelock) {
      if (owner !== safe) {
        throw new Error(`${name} owner is ${owner}, not Governance Safe ${safe}; it requires a separate owner migration`);
      }
      operations.push({
        description: `transfer ${name} ownership to Timelock`,
        target: contract.address,
        data: contract.interface.encodeFunctionData("transferOwnership", [timelock]),
      });
    }
  }

  // DEFAULT_ADMIN_ROLE is last: revoking it earlier can make later revocations impossible.
  const revocationRoles = [...roles.slice(1), roles[0]];
  for (const { name, role } of revocationRoles) {
    for (const account of legacyAccounts) {
      if (await input.acl.hasRole(role, account)) {
        operations.push({
          description: `revoke ${name} from ${account}`,
          target: input.acl.address,
          data: input.acl.interface.encodeFunctionData("revokeRole", [role, account]),
        });
      }
    }
  }
  const hasAclRoleOperations = operations.some(({ description }) =>
    description.startsWith("grant ") || description.startsWith("revoke ")
  );
  if (hasAclRoleOperations && !safeIsDefaultAdmin) {
    throw new Error(`Governance Safe ${safe} lacks DEFAULT_ADMIN_ROLE required for ACL migration`);
  }
  return operations;
}

async function deployedOwnables(): Promise<Array<{ name: string; contract: Contract }>> {
  const contracts: Array<{ name: string; contract: Contract }> = [];
  for (const name of OWNABLE_DEPLOYMENTS) {
    const deployment = await deployments.getOrNull(name);
    if (!deployment && name === "TokenFaucetManager") continue;
    if (!deployment) throw new Error(`required ownable deployment is missing: ${name}`);
    contracts.push({ name, contract: await getDeployedContract(name) });
  }
  return contracts;
}

function parseLegacyAccounts(value: string): string[] {
  const accounts = value.split(",").map((entry) => entry.trim()).filter(Boolean);
  if (accounts.length === 0) throw new Error("at least one legacy admin account is required");
  return accounts.map(ethers.utils.getAddress);
}

export async function buildProtocolPermissionMigration(legacyAccountsCsv: string): Promise<PermissionOperation[]> {
  if (DRY_RUN !== DryRunExecutor.Safe) {
    throw new Error("permission migration must use DRY_RUN=Safe so the current Safe executes one ordered batch");
  }
  const acl = await getDeployedContract("PsyACLManager");
  const timelock = await getDeployedContract("ExecutorWithTimelock");
  const governanceSafe = ethers.utils.getAddress(await timelock.getAdmin());
  if (!MULTI_SIG || ethers.utils.getAddress(MULTI_SIG) !== governanceSafe) {
    throw new Error(`MULTI_SIG must equal Timelock admin ${governanceSafe}`);
  }
  const operations = await buildPermissionMigration({
    acl,
    timelockAddress: timelock.address,
    governanceSafe,
    ownables: await deployedOwnables(),
    legacyAccounts: parseLegacyAccounts(legacyAccountsCsv),
  });
  if (operations.length === 0) {
    console.log("permission migration is already complete for the supplied legacy accounts");
    return operations;
  }
  console.log(JSON.stringify(operations, null, 2));
  await dryRunMultipleEncodedData(
    operations.map(({ target }) => target),
    operations.map(({ data }) => data),
  );
  return operations;
}

export async function verifyProtocolPermissions(legacyAccountsCsv: string) {
  const acl = await getDeployedContract("PsyACLManager");
  const timelock = await getDeployedContract("ExecutorWithTimelock");
  const timelockAddress = ethers.utils.getAddress(timelock.address);
  const governanceSafe = ethers.utils.getAddress(await timelock.getAdmin());
  const legacyAccounts = [...new Set([...parseLegacyAccounts(legacyAccountsCsv), governanceSafe])]
    .filter((account) => account !== timelockAddress);
  const violations: string[] = [];
  for (const { name, role } of await adminRoles(acl)) {
    if (!(await acl.hasRole(role, timelockAddress))) violations.push(`Timelock lacks ${name}`);
    for (const account of legacyAccounts) {
      if (await acl.hasRole(role, account)) {
        violations.push(`${account} still has ${name}`);
      }
    }
  }
  if (!(await acl.hasRole(await acl.GUARDIAN_ROLE(), governanceSafe))) {
    violations.push("Governance Safe lacks GUARDIAN_ROLE");
  }
  for (const { name, contract } of await deployedOwnables()) {
    if (ethers.utils.getAddress(await contract.owner()) !== timelockAddress) {
      violations.push(`${name} is not owned by Timelock`);
    }
  }
  if (ethers.utils.getAddress(await timelock.getPendingAdmin()) !== ethers.constants.AddressZero) {
    violations.push("Timelock pending admin is not zero");
  }
  const provider = await getDeployedContract("PsyAddressesProvider");
  const configuredAcl = ethers.utils.getAddress(await provider.getAddress(await provider.ACL_MANAGER_ID()));
  if (configuredAcl !== ethers.utils.getAddress(acl.address)) violations.push("AddressesProvider points to a different ACL");
  if (violations.length !== 0) throw new Error(`permission verification failed:\n- ${violations.join("\n- ")}`);
  const result = { timelock: timelockAddress, governanceSafe, legacyAccounts };
  console.log(JSON.stringify(result, null, 2));
  return result;
}

export async function buildTimelockAdminTransfer(newAdmin: string, executionTime?: string): Promise<void> {
  if (DRY_RUN !== DryRunExecutor.SafeWithTimeLock) {
    throw new Error("Timelock admin nomination must use DRY_RUN=SafeWithTimeLock for the current Safe");
  }
  const timelock = await getDeployedContract("ExecutorWithTimelock");
  const currentAdmin = ethers.utils.getAddress(await timelock.getAdmin());
  if (!MULTI_SIG || ethers.utils.getAddress(MULTI_SIG) !== currentAdmin) {
    throw new Error(`MULTI_SIG must equal current Timelock admin ${currentAdmin}`);
  }
  const data = timelock.interface.encodeFunctionData("setPendingAdmin", [ethers.utils.getAddress(newAdmin)]);
  await dryRunEncodedData(timelock.address, data, executionTime);
}

export async function buildTimelockAdminAcceptance(): Promise<void> {
  if (DRY_RUN !== DryRunExecutor.Safe) throw new Error("Timelock admin acceptance must use DRY_RUN=Safe for the new Safe");
  const timelock = await getDeployedContract("ExecutorWithTimelock");
  const pendingAdmin = ethers.utils.getAddress(await timelock.getPendingAdmin());
  if (pendingAdmin === ethers.constants.AddressZero) throw new Error("Timelock has no pending admin");
  if (!MULTI_SIG || ethers.utils.getAddress(MULTI_SIG) !== pendingAdmin) {
    throw new Error(`MULTI_SIG must equal pending Timelock admin ${pendingAdmin}`);
  }
  await dryRunEncodedData(timelock.address, timelock.interface.encodeFunctionData("acceptAdmin"));
}
