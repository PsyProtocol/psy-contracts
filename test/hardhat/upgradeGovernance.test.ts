import { expect } from "chai";
import { Contract } from "ethers";
import { ethers, network } from "hardhat";
import {
  defaultFlowConfig,
  deployAccessLayer,
  getChecksumAddress,
  getContractAddress,
  getDefaultAbiCoder,
  hexDataSlice,
  hexZeroPad,
  readStorageAt,
  waitForContractDeployment,
  wireCoreAddresses,
} from "./helpers/deploySystem";

const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

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
  const adminAddress = getChecksumAddress(hexDataSlice(adminRaw, 12));
  const proxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
  const proxyAdmin = proxyAdminFactory.attach(adminAddress) as any;
  const proxy = implementationFactory.attach(proxyAddress) as any;
  if (proxy.address == null) proxy.address = proxyAddress;
  if (proxyAdmin.address == null) proxyAdmin.address = adminAddress;
  return { proxy, proxyAdmin };
}

async function deploySystemWithTransparentBridge(owner: string, proposer: string) {
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
  const wethAddress = await getContractAddress(weth);
  const ethGateway = await deployTransparent("ETHGateway", owner, [owner, providerAddress, wethAddress]);

  await wireCoreAddresses({
    provider,
    acl,
    bridge: bridge.proxy,
    stateManager: state.proxy,
    router: router.proxy,
    erc20Gateway: erc20Gateway.proxy,
    ethGateway: ethGateway.proxy,
    verifier,
  });

  return { provider, acl, verifier, state, bridge, router, erc20Gateway, ethGateway, weth };
}

describe("governance upgrade and rescue", function () {
  it("queues, executes, and cancels timelock actions", async function () {
    const [admin] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("ExecutorWithTimelock");
    const timelock = await factory.deploy(admin.address, 3600, 7 * 24 * 3600, 60, 7 * 24 * 3600);
    await waitForContractDeployment(timelock);
    const timelockAddress = await getContractAddress(timelock);
    if ((timelock as any).address == null) (timelock as any).address = timelockAddress;

    const block = await ethers.provider.getBlock("latest");
    const executionTime = block.timestamp + 3601;
    const data = getDefaultAbiCoder().encode(["uint256"], [7200]);
    await expect(
      timelock.queueTransaction(timelockAddress, 0, "setDelay(uint256)", data, executionTime, false),
    ).to.emit(timelock, "QueuedAction");

    await expect(
      timelock.executeTransaction(timelockAddress, 0, "setDelay(uint256)", data, executionTime, false),
    ).to.be.revertedWith("TIMELOCK_NOT_FINISHED");

    await network.provider.send("evm_increaseTime", [3601]);
    await network.provider.send("evm_mine");
    await expect(
      timelock.executeTransaction(timelockAddress, 0, "setDelay(uint256)", data, executionTime, false),
    ).to.emit(timelock, "NewDelay").withArgs(7200);
    expect(await timelock.getDelay()).to.equal(7200);

    const cancelBlock = await ethers.provider.getBlock("latest");
    const cancelExecutionTime = cancelBlock.timestamp + 7201;
    const cancelData = getDefaultAbiCoder().encode(["uint256"], [3600]);
    await timelock.queueTransaction(timelockAddress, 0, "setDelay(uint256)", cancelData, cancelExecutionTime, false);
    await expect(
      timelock.cancelTransaction(timelockAddress, 0, "setDelay(uint256)", cancelData, cancelExecutionTime, false),
    ).to.emit(timelock, "CancelledAction");
  });

  it("upgrades StateManager in place and repairs continuity without changing storage layout", async function () {
    const [owner, proposer, other] = await ethers.getSigners();
    const { acl, state } = await deploySystemWithTransparentBridge(owner.address, proposer.address);

    const depositRoot = hexZeroPad("0x11", 32);
    const withdrawalRoot = hexZeroPad("0x22", 32);
    await acl.grantRole(await acl.STATE_MANAGER_ADMIN_ROLE(), owner.address);

    const implementationFactory = await ethers.getContractFactory("StateManager");
    const implementation = await implementationFactory.deploy();
    await waitForContractDeployment(implementation);
    await state.proxyAdmin.upgradeAndCall(state.proxy.address, await getContractAddress(implementation), "0x");
    const upgraded = implementationFactory.attach(state.proxy.address) as any;
    if (upgraded.address == null) upgraded.address = state.proxy.address;

    expect(await upgraded.getRevision()).to.equal(2);
    expect(await upgraded.addressesProvider()).to.equal(await state.proxy.addressesProvider());
    await expect(
      upgraded.connect(other).forceSetState(
        10,
        depositRoot,
        depositRoot,
        depositRoot,
        withdrawalRoot,
        withdrawalRoot,
      ),
    ).to.be.revertedWithCustomError(upgraded, "UnauthorizedStateManagerAdmin");
    await expect(
      upgraded.forceSetState(
        10,
        depositRoot,
        depositRoot,
        depositRoot,
        withdrawalRoot,
        withdrawalRoot,
      ),
    ).to.emit(upgraded, "ForceSetState");
    expect(await upgraded.lastFinalizedCheckpointId()).to.equal(10);
    expect(await upgraded.lastVerifiedCheckpointRoot()).to.equal(depositRoot);
    expect(await upgraded.lastVerifiedDepositTreeRoot()).to.equal(depositRoot);
    expect(await upgraded.lastVerifiedWithdrawalTreeRoot()).to.equal(withdrawalRoot);
    expect(await upgraded.withdrawalSubtreeRoot()).to.equal(withdrawalRoot);
    expect(await upgraded.knownDepositSubtreeRoots(depositRoot)).to.equal(true);
    expect(await upgraded.knownWithdrawalSubtreeRoots(withdrawalRoot)).to.equal(true);
    await expect(
      upgraded.forceSetState(
        9,
        depositRoot,
        depositRoot,
        depositRoot,
        withdrawalRoot,
        withdrawalRoot,
      ),
    ).to.be.revertedWithCustomError(upgraded, "InvalidForceSetState");
  });

  it("upgrades Bridge in place and rescues ERC20 and native funds via BRIDGE_ADMIN_ROLE", async function () {
    const [owner, proposer, recipient, other] = await ethers.getSigners();
    const { bridge } = await deploySystemWithTransparentBridge(owner.address, proposer.address);

    const tokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await tokenFactory.deploy("Mock", "MOCK");
    await waitForContractDeployment(token);
    const implementationFactory = await ethers.getContractFactory("Bridge");
    const implementation = await implementationFactory.deploy();
    await waitForContractDeployment(implementation);
    const initData = implementationFactory.interface.encodeFunctionData("initializeFlowLimits", [
      [await getContractAddress(token)],
      [defaultFlowConfig()],
    ]);
    await bridge.proxyAdmin.upgradeAndCall(
      bridge.proxy.address,
      await getContractAddress(implementation),
      initData,
    );
    const upgraded = implementationFactory.attach(bridge.proxy.address) as any;
    if (upgraded.address == null) upgraded.address = bridge.proxy.address;
    expect(await upgraded.getRevision()).to.equal(3);
    expect((await upgraded.getTokenFlowConfig(await getContractAddress(token))).configured).to.equal(true);
    await token.mint(upgraded.address, 1000);

    await expect(
      upgraded.connect(other).rescueERC20(await getContractAddress(token), recipient.address, 100),
    ).to.be.revertedWithCustomError(upgraded, "UnauthorizedBridgeAdmin");
    await upgraded.setGlobalPauseFlags(7);
    await expect(upgraded.rescueERC20(await getContractAddress(token), recipient.address, 100)).to.emit(upgraded, "ERC20Rescued");
    expect(await token.balanceOf(recipient.address)).to.equal(100);

    await owner.sendTransaction({ to: upgraded.address, value: 1234 });
    const before = BigInt((await ethers.provider.getBalance(recipient.address)).toString());
    await expect(upgraded.rescueNative(recipient.address, 1234)).to.emit(upgraded, "NativeRescued");
    const after = BigInt((await ethers.provider.getBalance(recipient.address)).toString());
    expect(after - before).to.equal(1234n);
  });
});
