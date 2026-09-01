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
  tokenSetHash,
  waitForContractDeployment,
  wireCoreAddresses,
} from "./helpers/deploySystem";
import { forceSetBridgeState } from "../../scripts/upgrade/forceSetBridgeState";
import { forceSetState } from "../../scripts/upgrade/forceSetState";

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

async function deployTransparentWithImplementation(
  implementationName: string,
  interfaceName: string,
  owner: string,
  initArgs: unknown[],
): Promise<{ proxy: Contract; proxyAdmin: Contract }> {
  const implementationFactory = await ethers.getContractFactory(implementationName);
  const implementation = await implementationFactory.deploy();
  await waitForContractDeployment(implementation);
  const implementationAddress = await getContractAddress(implementation);
  const initData = implementationFactory.interface.encodeFunctionData("initialize", initArgs);
  const proxyFactory = await ethers.getContractFactory("TestTransparentUpgradeableProxy");
  const proxyContract = await proxyFactory.deploy(implementationAddress, owner, initData);
  await waitForContractDeployment(proxyContract);
  const proxyAddress = await getContractAddress(proxyContract);
  const adminAddress = getChecksumAddress(hexDataSlice(await readStorageAt(proxyAddress, ADMIN_SLOT), 12));
  const proxyAdmin = (await ethers.getContractFactory("ProxyAdmin")).attach(adminAddress) as any;
  const proxy = (await ethers.getContractFactory(interfaceName)).attach(proxyAddress) as any;
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
  it("migrates the deployed V3 flow-config mapping into V4 storage atomically", async function () {
    const [owner] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Legacy", "LEG");
    await waitForContractDeployment(token);
    const tokenAddress = await getContractAddress(token);
    const legacy = await deployTransparentWithImplementation(
      "LegacyBridgeV3",
      "LegacyBridgeV3",
      owner.address,
      [owner.address, owner.address, owner.address, owner.address],
    );
    await legacy.proxy.initializeFlowLimits([tokenAddress], [[
      10, 20, 3, 40, 5, 60, 7, 8, 9, true,
    ]]);

    const nextConfig = defaultFlowConfig({
      minDepositAmount: 11,
      depositCap: 22,
      smallWithdrawalMax: 33,
      mediumWithdrawalMax: 44,
      totalWithdrawalCap: 55,
      smallWithdrawalDelay: 6,
      mediumWithdrawalDelay: 7,
      largeWithdrawalDelay: 8,
    });
    const executor = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(
      owner.address, 1, 1, 1, 1,
    );
    await waitForContractDeployment(executor);
    const bridgeFactory = await ethers.getContractFactory("Bridge");
    const implementation = await bridgeFactory.deploy();
    await waitForContractDeployment(implementation);
    const initData = bridgeFactory.interface.encodeFunctionData("initializeWithdrawalTotals", [
      [tokenAddress],
      [nextConfig],
      [66],
      tokenSetHash([tokenAddress]),
      await getContractAddress(executor),
    ]);
    await legacy.proxyAdmin.upgradeAndCall(
      legacy.proxy.address,
      await getContractAddress(implementation),
      initData,
    );

    const upgraded = bridgeFactory.attach(legacy.proxy.address) as any;
    if (upgraded.address == null) upgraded.address = legacy.proxy.address;
    const migrated = await upgraded.getTokenFlowConfig(tokenAddress);
    expect(migrated.minDepositAmount).to.equal(11);
    expect(migrated.depositCap).to.equal(22);
    expect(migrated.smallWithdrawalMax).to.equal(33);
    expect(migrated.mediumWithdrawalMax).to.equal(44);
    expect(migrated.totalWithdrawalCap).to.equal(55);
    expect(migrated.smallWithdrawalDelay).to.equal(6);
    expect(migrated.mediumWithdrawalDelay).to.equal(7);
    expect(migrated.largeWithdrawalDelay).to.equal(8);
    expect(migrated.configured).to.equal(true);
    expect(await upgraded.totalWithdrawalAmount(tokenAddress)).to.equal(66);
  });

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

  it("upgrades StateManager and Bridge in place and force-sets non-mapping state without touching mappings", async function () {
    const [owner, proposer, other] = await ethers.getSigners();
    const { acl, state, bridge, router, erc20Gateway } = await deploySystemWithTransparentBridge(owner.address, proposer.address);
    await acl.grantRole(await acl.STATE_MANAGER_ADMIN_ROLE(), owner.address);

    const stateFactory = await ethers.getContractFactory("StateManager");
    const stateImplementation = await stateFactory.deploy();
    await waitForContractDeployment(stateImplementation);
    await state.proxyAdmin.upgradeAndCall(state.proxy.address, await getContractAddress(stateImplementation), "0x");
    const upgradedState = stateFactory.attach(state.proxy.address) as any;
    if (upgradedState.address == null) upgradedState.address = state.proxy.address;

    const expectedState = {
      lastFinalizedCheckpointId: 0,
      lastVerifiedCheckpointRoot: ethers.constants.HashZero,
      lastVerifiedDepositTreeRoot: ethers.constants.HashZero,
      lastVerifiedWithdrawalTreeRoot: ethers.constants.HashZero,
      withdrawalSubtreeRoot: ethers.constants.HashZero,
    };
    const targetState = {
      lastFinalizedCheckpointId: 0,
      lastVerifiedCheckpointRoot: hexZeroPad("0x11", 32),
      lastVerifiedDepositTreeRoot: hexZeroPad("0x12", 32),
      lastVerifiedWithdrawalTreeRoot: hexZeroPad("0x13", 32),
      withdrawalSubtreeRoot: hexZeroPad("0x14", 32),
    };
    const untouchedStateMappingKey = hexZeroPad("0xab", 32);

    expect(await upgradedState.getRevision()).to.equal(2);
    expect(await upgradedState.addressesProvider()).to.equal(await state.proxy.addressesProvider());
    await expect(
      upgradedState.connect(other).forceSetState(expectedState, targetState),
    ).to.be.revertedWithCustomError(upgradedState, "UnauthorizedStateManagerAdmin");
    await expect(upgradedState.forceSetState(expectedState, targetState)).to.emit(upgradedState, "ForceSetState");
    expect(await upgradedState.lastFinalizedCheckpointId()).to.equal(targetState.lastFinalizedCheckpointId);
    expect(await upgradedState.lastVerifiedCheckpointRoot()).to.equal(targetState.lastVerifiedCheckpointRoot);
    expect(await upgradedState.lastVerifiedDepositTreeRoot()).to.equal(targetState.lastVerifiedDepositTreeRoot);
    expect(await upgradedState.lastVerifiedWithdrawalTreeRoot()).to.equal(targetState.lastVerifiedWithdrawalTreeRoot);
    expect(await upgradedState.withdrawalSubtreeRoot()).to.equal(targetState.withdrawalSubtreeRoot);
    expect(await upgradedState.knownDepositSubtreeRoots(ethers.constants.HashZero)).to.equal(true);
    expect(await upgradedState.knownWithdrawalSubtreeRoots(ethers.constants.HashZero)).to.equal(true);
    expect(await upgradedState.knownDepositSubtreeRoots(untouchedStateMappingKey)).to.equal(false);
    expect(await upgradedState.knownWithdrawalSubtreeRoots(untouchedStateMappingKey)).to.equal(false);
    await expect(upgradedState.forceSetState(expectedState, targetState)).to.not.emit(upgradedState, "ForceSetState");

    const tokenFactory = await ethers.getContractFactory("MockERC20");
    const depositToken = await tokenFactory.deploy("Deposit", "DEP");
    await waitForContractDeployment(depositToken);
    const preservedConfig = defaultFlowConfig({ totalWithdrawalCap: 777 });
    const forceClaimExecutor = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(
      owner.address, 1, 1, 1, 1,
    );
    await waitForContractDeployment(forceClaimExecutor);
    await bridge.proxy.initializeFlowLimits([depositToken.address], [preservedConfig]);
    const bridgeFactory = await ethers.getContractFactory("Bridge");
    const bridgeImplementation = await bridgeFactory.deploy();
    await waitForContractDeployment(bridgeImplementation);
    const bridgeInitData = bridgeFactory.interface.encodeFunctionData("initializeWithdrawalTotals", [
      [depositToken.address],
      [preservedConfig],
      [1234],
      tokenSetHash([depositToken.address]),
      await getContractAddress(forceClaimExecutor),
    ]);
    await bridge.proxyAdmin.upgradeAndCall(
      bridge.proxy.address,
      await getContractAddress(bridgeImplementation),
      bridgeInitData,
    );
    const upgradedBridge = bridgeFactory.attach(bridge.proxy.address) as any;
    if (upgradedBridge.address == null) upgradedBridge.address = bridge.proxy.address;

    await router.proxy.setTokenMapping(depositToken.address, hexZeroPad("0x2222", 32));
    await depositToken.mint(owner.address, 1);
    await depositToken.approve(erc20Gateway.proxy.address, 1);
    await router.proxy.deposit(depositToken.address, 1, hexZeroPad("0x23", 32), hexZeroPad("0x24", 32));
    const depositLeafHash = await upgradedBridge.depositLeafHashes(0);

    const expectedBridge = {
      depositRoot: await upgradedBridge.depositRoot(),
      provedDepositCount: 0,
      pendingDepositCount: 1,
      depositFrontier: await upgradedBridge.getDepositFrontier(),
    };
    const targetFrontier = [...expectedBridge.depositFrontier];
    targetFrontier[0] = hexZeroPad("0x31", 32);
    const targetBridge = {
      depositRoot: hexZeroPad("0x32", 32),
      provedDepositCount: 0,
      pendingDepositCount: 0,
      depositFrontier: targetFrontier,
    };
    const untouchedNullifier = hexZeroPad("0xcd", 32);

    expect(await upgradedBridge.getRevision()).to.equal(4);
    expect((await upgradedBridge.getTokenFlowConfig(depositToken.address)).totalWithdrawalCap).to.equal(777);
    expect(await upgradedBridge.totalWithdrawalAmount(depositToken.address)).to.equal(1234);
    expect(await upgradedBridge.withdrawalForceClaimExecutor()).to.equal(await getContractAddress(forceClaimExecutor));
    expect(await upgradedBridge.withdrawalTotalsTokenSetHash()).to.equal(tokenSetHash([depositToken.address]));
    await expect(
      upgradedBridge.connect(other).forceSetState(expectedBridge, targetBridge),
    ).to.be.revertedWithCustomError(upgradedBridge, "UnauthorizedBridgeAdmin");
    await expect(upgradedBridge.forceSetState(expectedBridge, targetBridge)).to.emit(upgradedBridge, "ForceSetState");
    expect(await upgradedBridge.depositRoot()).to.equal(targetBridge.depositRoot);
    expect(await upgradedBridge.provedDepositCount()).to.equal(targetBridge.provedDepositCount);
    expect(await upgradedBridge.pendingDepositCount()).to.equal(targetBridge.pendingDepositCount);
    expect(await upgradedBridge.getDepositFrontier()).to.deep.equal(targetBridge.depositFrontier);
    expect(await upgradedBridge.depositLeafHashes(0)).to.equal(depositLeafHash);
    expect(await upgradedBridge.claimedNullifiers(untouchedNullifier)).to.equal(false);
    await expect(upgradedBridge.forceSetState(expectedBridge, targetBridge)).to.not.emit(upgradedBridge, "ForceSetState");
  });

  it("rejects invalid force-set script invariants before deployment lookup", async function () {
    const zero = ethers.constants.HashZero;
    process.env.EXPECTED_LAST_FINALIZED_CHECKPOINT_ID = "1";
    process.env.EXPECTED_LAST_VERIFIED_CHECKPOINT_ROOT = zero;
    process.env.EXPECTED_LAST_VERIFIED_DEPOSIT_TREE_ROOT = zero;
    process.env.EXPECTED_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT = zero;
    process.env.EXPECTED_WITHDRAWAL_SUBTREE_ROOT = zero;
    process.env.NEW_LAST_FINALIZED_CHECKPOINT_ID = "2";
    process.env.NEW_LAST_VERIFIED_CHECKPOINT_ROOT = zero;
    process.env.NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT = zero;
    process.env.NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT = zero;
    process.env.NEW_WITHDRAWAL_SUBTREE_ROOT = zero;
    await expect(forceSetState()).to.be.rejectedWith(
      "NEW_LAST_FINALIZED_CHECKPOINT_ID must not exceed EXPECTED_LAST_FINALIZED_CHECKPOINT_ID",
    );

    const frontier = JSON.stringify(Array(32).fill(zero));
    process.env.EXPECTED_BRIDGE_DEPOSIT_ROOT = zero;
    process.env.EXPECTED_BRIDGE_PROVED_DEPOSIT_COUNT = "1";
    process.env.EXPECTED_BRIDGE_PENDING_DEPOSIT_COUNT = "1";
    process.env.EXPECTED_BRIDGE_DEPOSIT_FRONTIER_JSON = frontier;
    process.env.NEW_BRIDGE_DEPOSIT_ROOT = zero;
    process.env.NEW_BRIDGE_PROVED_DEPOSIT_COUNT = "2";
    process.env.NEW_BRIDGE_PENDING_DEPOSIT_COUNT = "1";
    process.env.NEW_BRIDGE_DEPOSIT_FRONTIER_JSON = frontier;
    await expect(forceSetBridgeState()).to.be.rejectedWith(
      "NEW_BRIDGE_PROVED_DEPOSIT_COUNT must not exceed NEW_BRIDGE_PENDING_DEPOSIT_COUNT",
    );
  });

  it("upgrades Bridge in place and rescues ERC20 and native funds via BRIDGE_ADMIN_ROLE", async function () {
    const [owner, proposer, recipient, other] = await ethers.getSigners();
    const { bridge } = await deploySystemWithTransparentBridge(owner.address, proposer.address);

    const tokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await tokenFactory.deploy("Mock", "MOCK");
    await waitForContractDeployment(token);
    const tokenAddress = await getContractAddress(token);
    await bridge.proxy.initializeFlowLimits([tokenAddress], [defaultFlowConfig({ totalWithdrawalCap: 555 })]);
    const forceClaimExecutor = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(
      owner.address, 1, 1, 1, 1,
    );
    await waitForContractDeployment(forceClaimExecutor);
    const implementationFactory = await ethers.getContractFactory("Bridge");
    const implementation = await implementationFactory.deploy();
    await waitForContractDeployment(implementation);
    const initData = implementationFactory.interface.encodeFunctionData("initializeWithdrawalTotals", [
      [tokenAddress],
      [defaultFlowConfig({ totalWithdrawalCap: 555 })],
      [987],
      tokenSetHash([tokenAddress]),
      await getContractAddress(forceClaimExecutor),
    ]);
    await bridge.proxyAdmin.upgradeAndCall(
      bridge.proxy.address,
      await getContractAddress(implementation),
      initData,
    );
    const upgraded = implementationFactory.attach(bridge.proxy.address) as any;
    if (upgraded.address == null) upgraded.address = bridge.proxy.address;
    expect(await upgraded.getRevision()).to.equal(4);
    expect((await upgraded.getTokenFlowConfig(tokenAddress)).totalWithdrawalCap).to.equal(555);
    expect(await upgraded.totalWithdrawalAmount(tokenAddress)).to.equal(987);
    expect(await upgraded.withdrawalForceClaimExecutor()).to.equal(await getContractAddress(forceClaimExecutor));
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
