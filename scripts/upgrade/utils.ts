import { Contract } from "ethers";
import { ethers } from "hardhat";
import { dryRunEncodedData, getDeployedContract, waitForTx } from "../../helpers/contracts-helpers";
import { DRY_RUN, DryRunExecutor, GLOBAL_OVERRIDES } from "../../helpers/hardhat-constants";

export const UPGRADEABLE_CONTRACTS = [
  "PsyAddressesProvider",
  "PsyACLManager",
  "StateManager",
  "Bridge",
  "Router",
  "ERC20Gateway",
  "ETHGateway",
  "TokenFaucetManager",
] as const;

export type UpgradeableContractName = typeof UPGRADEABLE_CONTRACTS[number];

const DEFAULT_IMPLEMENTATION: Record<UpgradeableContractName, string> = {
  PsyAddressesProvider: "PsyAddressesProvider",
  PsyACLManager: "PsyACLManager",
  StateManager: "StateManager",
  Bridge: "Bridge",
  Router: "Router",
  ERC20Gateway: "ERC20Gateway",
  ETHGateway: "ETHGateway",
  TokenFaucetManager: "TokenFaucetManager",
};

export function isUpgradeableContractName(name: string): name is UpgradeableContractName {
  return (UPGRADEABLE_CONTRACTS as readonly string[]).includes(name);
}

async function waitForContractDeployment(contract: any): Promise<void> {
  if (typeof contract.waitForDeployment === "function") {
    await contract.waitForDeployment();
    return;
  }
  if (typeof contract.deployed === "function") {
    await contract.deployed();
    return;
  }
  throw new Error("Unsupported ethers contract deployment API");
}

async function getContractAddress(contract: any): Promise<string> {
  if (typeof contract.address === "string") {
    return contract.address;
  }
  if (typeof contract.target === "string") {
    return contract.target;
  }
  if (typeof contract.getAddress === "function" && contract.interface?.getFunction?.("getAddress") == null) {
    return await contract.getAddress();
  }
  throw new Error("Unable to resolve deployed contract address");
}

export async function deployImplementation(implementationName: string): Promise<string> {
  const factory = await ethers.getContractFactory(implementationName);
  const implementation = await factory.deploy();
  await waitForContractDeployment(implementation);
  const implementationAddress = await getContractAddress(implementation);
  console.log(`${implementationName} implementation: ${implementationAddress}`);
  return implementationAddress;
}

function hasFunction(contract: Contract, signature: string): boolean {
  try {
    contract.interface.getFunction(signature);
    return true;
  } catch {
    return false;
  }
}

async function isProxyAdminOwnedByTimelock(proxyAdmin: Contract): Promise<boolean> {
  try {
    const timelock = await getDeployedContract("ExecutorWithTimelock");
    const timelockAddress = await getContractAddress(timelock);
    const proxyAdminOwner = await proxyAdmin.owner();
    return String(proxyAdminOwner).toLowerCase() === timelockAddress.toLowerCase();
  } catch {
    return false;
  }
}

async function assertUpgradeModeCompatible(proxyAdmin: Contract): Promise<void> {
  if (!(await isProxyAdminOwnedByTimelock(proxyAdmin))) return;
  if (DRY_RUN === DryRunExecutor.TimeLock || DRY_RUN === DryRunExecutor.SafeWithTimeLock) return;
  throw new Error(
    "DefaultProxyAdmin is owned by ExecutorWithTimelock; use DRY_RUN=TimeLock or DRY_RUN=SafeWithTimeLock.",
  );
}

async function encodeUpgrade(
  proxyAdmin: Contract,
  proxy: string,
  implementation: string,
  upgradeCallData: string,
): Promise<string> {
  const supportsUpgrade = hasFunction(proxyAdmin, "upgrade(address,address)");
  const supportsUpgradeAndCall = hasFunction(proxyAdmin, "upgradeAndCall(address,address,bytes)");
  if (upgradeCallData !== "0x" || !supportsUpgrade) {
    if (!supportsUpgradeAndCall) throw new Error("ProxyAdmin does not support atomic upgradeAndCall");
    return proxyAdmin.interface.encodeFunctionData("upgradeAndCall", [proxy, implementation, upgradeCallData]);
  }
  return proxyAdmin.interface.encodeFunctionData("upgrade", [proxy, implementation]);
}

async function executeUpgrade(
  proxyAdmin: Contract,
  proxy: string,
  implementation: string,
  upgradeCallData: string,
): Promise<void> {
  const supportsUpgrade = hasFunction(proxyAdmin, "upgrade(address,address)");
  const supportsUpgradeAndCall = hasFunction(proxyAdmin, "upgradeAndCall(address,address,bytes)");
  if (upgradeCallData !== "0x" || !supportsUpgrade) {
    if (!supportsUpgradeAndCall) throw new Error("ProxyAdmin does not support atomic upgradeAndCall");
    await waitForTx(await proxyAdmin.upgradeAndCall(proxy, implementation, upgradeCallData, GLOBAL_OVERRIDES));
    return;
  }
  await waitForTx(await proxyAdmin.upgrade(proxy, implementation, GLOBAL_OVERRIDES));
}

export async function upgradeContract(
  contractName: UpgradeableContractName,
  implementationName = DEFAULT_IMPLEMENTATION[contractName],
  executionTime?: string,
  upgradeCallData = "0x",
): Promise<{ proxy: string; implementation: string; calldata: string }> {
  const proxyAdmin = await getDeployedContract("DefaultProxyAdmin");
  const proxy = await getDeployedContract(`${contractName}_Proxy`);
  const proxyAddress = await getContractAddress(proxy);
  const proxyAdminAddress = await getContractAddress(proxyAdmin);
  const implementation = await deployImplementation(implementationName);
  await assertUpgradeModeCompatible(proxyAdmin);
  const calldata = await encodeUpgrade(proxyAdmin, proxyAddress, implementation, upgradeCallData);

  if (DRY_RUN === DryRunExecutor.Run) {
    await dryRunEncodedData(proxyAdminAddress, calldata, executionTime);
  } else if (DRY_RUN) {
    await dryRunEncodedData(proxyAdminAddress, calldata, executionTime);
  } else {
    await executeUpgrade(proxyAdmin, proxyAddress, implementation, upgradeCallData);
  }

  return { proxy: proxyAddress, implementation, calldata };
}

export async function upgradeAllContracts(executionTime: string | undefined, bridgeUpgradeCallData: string): Promise<void> {
  if (bridgeUpgradeCallData === "0x") {
    throw new Error("Bridge V4 requires non-empty initializeWithdrawalTotals calldata");
  }
  for (const name of UPGRADEABLE_CONTRACTS) {
    await upgradeContract(
      name,
      DEFAULT_IMPLEMENTATION[name],
      executionTime,
      name === "Bridge" ? bridgeUpgradeCallData : "0x",
    );
  }
}
