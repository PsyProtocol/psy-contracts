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
  stripAdmins: string[];
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
  const stripAdmins = [...new Set([...input.stripAdmins.map(ethers.utils.getAddress), safe])]
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

  // The Governance Safe executes this batch and must keep DEFAULT_ADMIN_ROLE until every other
  // revocation has run, so its own revocation is ordered last regardless of input order.
  const orderedAccounts = [
    ...stripAdmins.filter((account) => account !== safe),
    ...stripAdmins.filter((account) => account === safe),
  ];
  const revocationRoles = [...roles.slice(1), { name: "GUARDIAN_ROLE", role: guardianRole }, roles[0]];
  for (const { name, role } of revocationRoles) {
    for (const account of orderedAccounts) {
      if (account === safe && role === guardianRole) continue;
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

function parseStripAdmins(value: string): string[] {
  const accounts = value.split(",").map((entry) => entry.trim()).filter(Boolean);
  if (accounts.length === 0) throw new Error("at least one admin account to strip is required");
  return accounts.map(ethers.utils.getAddress);
}

export async function buildProtocolPermissionMigration(stripAdminsCsv: string): Promise<PermissionOperation[]> {
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
    stripAdmins: parseStripAdmins(stripAdminsCsv),
  });
  if (operations.length === 0) {
    console.log("permission migration is already complete for the supplied admin accounts");
    return operations;
  }
  console.log(JSON.stringify(operations, null, 2));
  await dryRunMultipleEncodedData(
    operations.map(({ target }) => target),
    operations.map(({ data }) => data),
  );
  return operations;
}

export async function verifyProtocolPermissions(stripAdminsCsv: string, expectedProposer?: string) {
  const acl = await getDeployedContract("PsyACLManager");
  const timelock = await getDeployedContract("ExecutorWithTimelock");
  const timelockAddress = ethers.utils.getAddress(timelock.address);
  const governanceSafe = ethers.utils.getAddress(await timelock.getAdmin());
  const stripAdmins = [...new Set([...parseStripAdmins(stripAdminsCsv), governanceSafe])]
    .filter((account) => account !== timelockAddress);
  const violations: string[] = [];
  const roles = await adminRoles(acl);
  for (const { name, role } of roles) {
    if (!(await acl.hasRole(role, timelockAddress))) violations.push(`Timelock lacks ${name}`);
    for (const account of stripAdmins) {
      if (await acl.hasRole(role, account)) {
        violations.push(`${account} still has ${name}`);
      }
    }
  }
  // The Governance Safe is the only listed account allowed to keep GUARDIAN_ROLE.
  const guardianRole = await acl.GUARDIAN_ROLE();
  for (const account of stripAdmins) {
    if (account === governanceSafe) continue;
    if (await acl.hasRole(guardianRole, account)) violations.push(`${account} still has GUARDIAN_ROLE`);
  }
  if (!(await acl.hasRole(guardianRole, governanceSafe))) {
    violations.push("Governance Safe lacks GUARDIAN_ROLE");
  }
  // Role separation: PROPOSER_ROLE is an operational bot role. It is deliberately NOT migrated or
  // revoked by the cutover batch, but governance and the proposer must be distinct addresses.
  const proposerRole = await acl.PROPOSER_ROLE();
  if (await acl.hasRole(proposerRole, timelockAddress)) violations.push("Timelock holds PROPOSER_ROLE");
  if (await acl.hasRole(proposerRole, governanceSafe)) violations.push("Governance Safe holds PROPOSER_ROLE");
  if (expectedProposer !== undefined) {
    const proposer = ethers.utils.getAddress(expectedProposer);
    if (proposer === timelockAddress) violations.push("proposer must not be the Timelock");
    if (proposer === governanceSafe) violations.push("proposer must not be the Governance Safe");
    if (!(await acl.hasRole(proposerRole, proposer))) {
      violations.push(`configured proposer ${proposer} does not hold PROPOSER_ROLE`);
    }
  } else {
    violations.push(
      "proposer must be configured: pass the dedicated PROPOSER_ROLE bot address (distinct from the Timelock and Governance Safe)"
    );
  }
  for (const account of stripAdmins) {
    if (await acl.hasRole(proposerRole, account)) {
      violations.push(`${account} still has PROPOSER_ROLE; PROPOSER_ROLE must belong to the dedicated bot address`);
    }
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
  const result = { timelock: timelockAddress, governanceSafe, stripAdmins };
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
