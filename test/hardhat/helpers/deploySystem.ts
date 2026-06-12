import { ethers } from "hardhat";
import { deployProxy } from "./deployProxy";

async function waitForContractDeployment(contract: any) {
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

  await provider.setAddress(await provider.ACL_MANAGER_ID(), acl.address);
  await provider.setAddress(await provider.BRIDGE_ID(), bridge.address);
  await provider.setAddress(await provider.STATE_MANAGER_ID(), stateManager.address);
  await provider.setAddress(await provider.ROUTER_ID(), router.address);
  await provider.setAddress(await provider.ERC20_GATEWAY_ID(), erc20Gateway.address);
  await provider.setAddress(await provider.ETH_GATEWAY_ID(), ethGateway.address);
  await provider.setAddress(await provider.ZK_VERIFIER_ID(), verifier.address);
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
