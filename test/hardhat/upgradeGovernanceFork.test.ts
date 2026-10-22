import { expect } from "chai";
import { Contract } from "ethers";
import { deployments, ethers, network } from "hardhat";
import { protocolConfig } from "../../protocol-config";
import {
  defaultFlowConfig,
  deployAccessLayer,
  ensureHardhatDeploymentChainId,
  getChecksumAddress,
  getContractAddress,
  hexDataSlice,
  hexZeroPad,
  readStorageAt,
  waitForContractDeployment,
  wireCoreAddresses,
} from "./helpers/deploySystem";

const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const maybeDescribe = process.env.RUN_FORK_UPGRADE_TESTS === "1" ? describe : describe.skip;
const HASH_ZERO = (ethers as any).ZeroHash ?? ethers.constants.HashZero;

async function deployTransparent(contractName: string, owner: string, initArgs: unknown[]): Promise<{ proxy: Contract; proxyAdmin: Contract }> {
  const implementationFactory = await ethers.getContractFactory(contractName);
  const implementation = await implementationFactory.deploy();
  await waitForContractDeployment(implementation);
  const implementationAddress = await getContractAddress(implementation);
  const initData = implementationFactory.interface.encodeFunctionData("initialize", initArgs);
  const proxyFactory = await ethers.getContractFactory("TestTransparentUpgradeableProxy");
  const proxyContract = await proxyFactory.deploy(implementationAddress, owner, initData);
  await waitForContractDeployment(proxyContract);
  const proxyAddress = await getContractAddress(proxyContract);
  const adminRaw = await readStorageAt(proxyAddress, ADMIN_SLOT);
  const proxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
  const adminAddress = getChecksumAddress(hexDataSlice(adminRaw, 12));
  const proxyAdmin = proxyAdminFactory.attach(adminAddress) as any;
  const proxy = implementationFactory.attach(proxyAddress) as any;
  if (proxy.address == null) proxy.address = proxyAddress;
  if (proxyAdmin.address == null) proxyAdmin.address = adminAddress;
  return { proxy, proxyAdmin };
}

const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
function slotAddress(raw: string): string {
  return getChecksumAddress(hexDataSlice(raw, 12));
}

async function implementationOf(proxy: string): Promise<string> {
  return slotAddress(await readStorageAt(proxy, IMPLEMENTATION_SLOT));
}

async function deployedContract(name: string): Promise<Contract> {
  const deployment = await deployments.get(name);
  const contract = await ethers.getContractAt(deployment.abi, deployment.address) as any;
  if (contract.address == null) contract.address = deployment.address;
  return contract;
}

async function deployForkSystem(owner: string, proposer: string) {
  const { provider, acl } = await deployAccessLayer(owner, proposer);
  const verifierFactory = await ethers.getContractFactory("MockGnarkVerifier");
  const verifier = await verifierFactory.deploy();
  await waitForContractDeployment(verifier);
  const depositBatchVerifier = await verifierFactory.deploy();
  await waitForContractDeployment(depositBatchVerifier);
  const providerAddress = await getContractAddress(provider);
  const verifierAddress = await getContractAddress(verifier);
  const depositBatchVerifierAddress = await getContractAddress(depositBatchVerifier);
  const state = await deployTransparent("StateManager", owner, [owner, providerAddress, 0]);
  const router = await deployTransparent("Router", owner, [owner, providerAddress]);
  const bridge = await deployTransparent("Bridge", owner, [owner, providerAddress, depositBatchVerifierAddress, verifierAddress]);
  const erc20Gateway = await deployTransparent("ERC20Gateway", owner, [owner, providerAddress]);
  const wethFactory = await ethers.getContractFactory("WETH9");
  const weth = await wethFactory.deploy();
  await waitForContractDeployment(weth);
  const ethGateway = await deployTransparent("ETHGateway", owner, [owner, providerAddress, await getContractAddress(weth)]);
  await wireCoreAddresses({ provider, acl, bridge: bridge.proxy, stateManager: state.proxy, router: router.proxy, erc20Gateway: erc20Gateway.proxy, ethGateway: ethGateway.proxy, verifier });
  return { acl, state, bridge };
}

maybeDescribe("fork governance upgrade and bridge rescue", function () {
  this.timeout(180000);
  before(async function () {
    const rpcUrl = process.env.SEPOLIA_RPC_URL || protocolConfig.chains.sepolia.defaultRpcUrl;
    const remoteProvider = new ethers.providers.JsonRpcProvider(rpcUrl);
    const configuredBlock = process.env.SEPOLIA_FORK_BLOCK;
    const blockNumber = configuredBlock
      ? Number(configuredBlock)
      : (await remoteProvider.getBlockNumber()) - 64;
    if (!Number.isSafeInteger(blockNumber) || blockNumber <= 0) {
      throw new Error(`Invalid SEPOLIA_FORK_BLOCK: ${configuredBlock ?? blockNumber}`);
    }
    await network.provider.request({
      method: "hardhat_reset",
      params: [{ forking: { jsonRpcUrl: rpcUrl, blockNumber } }],
    });
  });

  it("upgrades StateManager and Bridge in place on a Sepolia fork and rescues funds", async function () {
    const [owner, proposer, recipient] = await ethers.getSigners();
    const { acl, state, bridge } = await deployForkSystem(owner.address, proposer.address);
    await acl.grantRole(await acl.STATE_MANAGER_ADMIN_ROLE(), owner.address);

    const stateFactory = await ethers.getContractFactory("StateManager");
    const stateImpl = await stateFactory.deploy();
    await waitForContractDeployment(stateImpl);
    await state.proxyAdmin.upgradeAndCall(state.proxy.address, await getContractAddress(stateImpl), "0x");
    const upgradedState = stateFactory.attach(state.proxy.address) as any;
    if (upgradedState.address == null) upgradedState.address = state.proxy.address;
    await upgradedState.forceSetState(
      1,
      hexZeroPad("0x01", 32),
      HASH_ZERO,
      HASH_ZERO,
      HASH_ZERO,
      HASH_ZERO,
    );
    expect(await upgradedState.getRevision()).to.equal(2);
    expect(await upgradedState.lastFinalizedCheckpointId()).to.equal(1);

    const bridgeFactory = await ethers.getContractFactory("Bridge");
    const bridgeImpl = await bridgeFactory.deploy();
    await waitForContractDeployment(bridgeImpl);
    const tokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await tokenFactory.deploy("ForkMock", "FMK");
    await waitForContractDeployment(token);
    const tokenAddress = await getContractAddress(token);
    const initData = bridgeFactory.interface.encodeFunctionData("initializeFlowLimits", [
      [tokenAddress],
      [defaultFlowConfig()],
    ]);
    await bridge.proxyAdmin.upgradeAndCall(bridge.proxy.address, await getContractAddress(bridgeImpl), initData);
    const upgradedBridge = bridgeFactory.attach(bridge.proxy.address) as any;
    if (upgradedBridge.address == null) upgradedBridge.address = bridge.proxy.address;
    expect((await upgradedBridge.getTokenFlowConfig(tokenAddress)).configured).to.equal(true);
    await token.mint(upgradedBridge.address, 123);
    await upgradedBridge.setGlobalPauseFlags(7);
    await expect(upgradedBridge.rescueERC20(tokenAddress, recipient.address, 123)).to.emit(upgradedBridge, "ERC20Rescued");
    expect(await token.balanceOf(recipient.address)).to.equal(123);
  });

  it("executes upgrade, force-set-state, and rescue scripts on a Sepolia fork deployment", async function () {
    const [, recipient] = await ethers.getSigners();
    await ensureHardhatDeploymentChainId();
    process.env.PSY_SKIP_BRIDGE_FLOW_LIMITS = "1";
    await deployments.fixture(["token_faucet", "timelock_roles"]);
    delete process.env.PSY_SKIP_BRIDGE_FLOW_LIMITS;

    const { UPGRADEABLE_CONTRACTS, upgradeAllContracts } = await import("../../scripts/upgrade/utils");
    const bridgeFactory = await ethers.getContractFactory("Bridge");
    const usdtDeployment = await deployments.get("USDTToken");
    const bridgeInitData = bridgeFactory.interface.encodeFunctionData("initializeFlowLimits", [
      [usdtDeployment.address],
      [defaultFlowConfig()],
    ]);
    const beforeImplementations = new Map<string, string>();
    const proxyAddresses = new Map<string, string>();
    for (const name of UPGRADEABLE_CONTRACTS) {
      const proxy = await deployments.get(`${name}_Proxy`);
      proxyAddresses.set(name, proxy.address);
      beforeImplementations.set(name, await implementationOf(proxy.address));
    }

    await upgradeAllContracts(undefined, bridgeInitData);

    for (const name of UPGRADEABLE_CONTRACTS) {
      const proxy = await deployments.get(`${name}_Proxy`);
      expect(proxy.address).to.equal(proxyAddresses.get(name));
      expect(await implementationOf(proxy.address)).to.not.equal(beforeImplementations.get(name));
    }

    const { forceSetState } = await import("../../scripts/upgrade/forceSetState");
    process.env.NEW_LAST_FINALIZED_CHECKPOINT_ID = "11";
    process.env.NEW_LAST_VERIFIED_CHECKPOINT_ROOT = hexZeroPad("0x11", 32);
    process.env.NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT = hexZeroPad("0x12", 32);
    process.env.NEW_DEPOSIT_SUBTREE_ROOT = hexZeroPad("0x21", 32);
    process.env.NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT = hexZeroPad("0x13", 32);
    process.env.NEW_WITHDRAWAL_SUBTREE_ROOT = hexZeroPad("0x14", 32);
    await forceSetState();
    const stateManager = await deployedContract("StateManager");
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(11);

    const { rescueBridgeFunds } = await import("../../scripts/upgrade/rescueBridgeFunds");
    const bridge = await deployedContract("Bridge");
    const token = await deployedContract("USDTToken");
    await token.transfer(bridge.address, 1000);
    await bridge.setGlobalPauseFlags(7);
    process.env.RESCUE_MODE = "erc20";
    process.env.RESCUE_TOKEN = token.address;
    process.env.RESCUE_TO = recipient.address;
    process.env.RESCUE_AMOUNT = "1000";
    await rescueBridgeFunds();
    expect(await token.balanceOf(recipient.address)).to.equal(1000);

    await recipient.sendTransaction({ to: bridge.address, value: 1234 });
    process.env.RESCUE_MODE = "native";
    process.env.RESCUE_AMOUNT = "1234";
    const nativeBalanceBefore = BigInt((await ethers.provider.getBalance(recipient.address)).toString());
    await rescueBridgeFunds();
    const nativeBalanceAfter = BigInt((await ethers.provider.getBalance(recipient.address)).toString());
    expect(nativeBalanceAfter - nativeBalanceBefore).to.equal(1234n);

    const weth = await deployedContract("WETH9");
    await weth.deposit({ value: 4321 });
    await weth.transfer(bridge.address, 4321);
    process.env.RESCUE_MODE = "weth-native";
    process.env.RESCUE_AMOUNT = "4321";
    const wethNativeBalanceBefore = BigInt((await ethers.provider.getBalance(recipient.address)).toString());
    await rescueBridgeFunds();
    const wethNativeBalanceAfter = BigInt((await ethers.provider.getBalance(recipient.address)).toString());
    expect(wethNativeBalanceAfter - wethNativeBalanceBefore).to.equal(4321n);
  });
});
