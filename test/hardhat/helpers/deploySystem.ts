import fs from "fs";
import path from "path";
import { ethers } from "hardhat";
import { deployProxy } from "./deployProxy";

export async function waitForContractDeployment(contract: any) {
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

export async function getContractAddress(contract: any): Promise<string> {
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

export async function ensureHardhatDeploymentChainId(): Promise<void> {
  const { chainId } = await ethers.provider.getNetwork();
  const deploymentDir = path.join(__dirname, "../../../deployments/hardhat");
  fs.mkdirSync(deploymentDir, { recursive: true });
  fs.writeFileSync(path.join(deploymentDir, ".chainId"), String(chainId));
}
export async function readStorageAt(address: string, slot: string): Promise<string> {
  const provider = ethers.provider as any;
  if (typeof provider.getStorageAt === "function") {
    return provider.getStorageAt(address, slot);
  }
  if (typeof provider.getStorage === "function") {
    return provider.getStorage(address, slot);
  }
  return provider.send("eth_getStorageAt", [address, slot, "latest"]);
}

export function getDefaultAbiCoder() {
  return (ethers as any).AbiCoder?.defaultAbiCoder?.() ?? ethers.utils.defaultAbiCoder;
}
export function getChecksumAddress(value: string): string {
  return (ethers as any).getAddress?.(value) ?? ethers.utils.getAddress(value);
}

export function hexDataSlice(value: string, start: number, end?: number): string {
  return (ethers as any).dataSlice?.(value, start, end) ?? ethers.utils.hexDataSlice(value, start, end);
}

export function hexZeroPad(value: string, length: number): string {
  return (ethers as any).zeroPadValue?.(value, length) ?? ethers.utils.hexZeroPad(value, length);
}

export function defaultFlowConfig(overrides: Record<string, unknown> = {}) {
  return {
    minDepositAmount: 1,
    depositCapacity: 1_000_000_000_000n,
    depositRefillPerSecond: 1_000_000,
    custodyCap: 10_000_000_000_000n,
    smallWithdrawalMax: 1_000,
    mediumWithdrawalMax: 10_000,
    smallWithdrawalDelay: 0,
    mediumWithdrawalDelay: 3600,
    largeWithdrawalDelay: 86400,
    configured: true,
    ...overrides,
  };
}

export async function configureFlowToken(bridge: any, token: string, overrides: Record<string, unknown> = {}) {
  const expectedHash = await bridge.getTokenFlowConfigHash(token);
  await bridge.setTokenFlowConfig(token, defaultFlowConfig(overrides), expectedHash);
}

export async function deployAccessLayer(admin: string, proposer?: string) {
  const proposerAddr = proposer ?? admin;
  const provider = await deployProxy("PsyAddressesProvider", [admin]);
  const acl = await deployProxy("PsyACLManager", [admin, admin, admin, admin, proposerAddr]);
  return { provider, acl };
}

export async function wireCoreAddresses(params: {
  provider: any;
  acl: any;
  bridge: any;
  stateManager: any;
  router: any;
  erc20Gateway: any;
  ethGateway: any;
  verifier: any;
}) {
  const { provider, acl, bridge, stateManager, router, erc20Gateway, ethGateway, verifier } = params;
  const aclAddress = await getContractAddress(acl);
  const bridgeAddress = await getContractAddress(bridge);
  const stateManagerAddress = await getContractAddress(stateManager);
  const routerAddress = await getContractAddress(router);
  const erc20GatewayAddress = await getContractAddress(erc20Gateway);
  const ethGatewayAddress = await getContractAddress(ethGateway);
  const verifierAddress = await getContractAddress(verifier);

  await provider.setAddress(await provider.ACL_MANAGER_ID(), aclAddress);
  await provider.setAddress(await provider.BRIDGE_ID(), bridgeAddress);
  await provider.setAddress(await provider.STATE_MANAGER_ID(), stateManagerAddress);
  await provider.setAddress(await provider.ROUTER_ID(), routerAddress);
  await provider.setAddress(await provider.ERC20_GATEWAY_ID(), erc20GatewayAddress);
  await provider.setAddress(await provider.ETH_GATEWAY_ID(), ethGatewayAddress);
  await provider.setAddress(await provider.ZK_VERIFIER_ID(), verifierAddress);
}

export async function deployCoreSystem(owner: string, proposer?: string) {
  const { provider, acl } = await deployAccessLayer(owner, proposer);
  const V = await ethers.getContractFactory("MockGnarkVerifier");
  const verifier = await V.deploy();
  await waitForContractDeployment(verifier);
  const batchVerifier = await V.deploy();
  await waitForContractDeployment(batchVerifier);

  const providerAddress = await getContractAddress(provider);
  const verifierAddress = await getContractAddress(verifier);
  const batchVerifierAddress = await getContractAddress(batchVerifier);
  const stateManager = await deployProxy("StateManager", [owner, providerAddress, 0]);
  const router = await deployProxy("Router", [owner, providerAddress]);
  const bridge = await deployProxy("Bridge", [
    owner,
    providerAddress,
    batchVerifierAddress,
    verifierAddress,
  ]);
  const erc20Gateway = await deployProxy("ERC20Gateway", [owner, providerAddress]);

  const WethFactory = await ethers.getContractFactory("WETH9");
  const weth = await WethFactory.deploy();
  await waitForContractDeployment(weth);
  const wethAddress = await getContractAddress(weth);
  const ethGateway = await deployProxy("ETHGateway", [owner, providerAddress, wethAddress]);

  await wireCoreAddresses({ provider, acl, bridge, stateManager, router, erc20Gateway, ethGateway, verifier });
  await acl.grantRole(await acl.GUARDIAN_ROLE(), owner);

  return {
    provider,
    acl,
    verifier,
    batchVerifier,
    stateManager,
    router,
    bridge,
    erc20Gateway,
    ethGateway,
    weth,
  };
}
