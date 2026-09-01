import { expect } from "chai";
import fs from "fs";
import os from "os";
import path from "path";
import hre, { deployments, ethers } from "hardhat";
import { buildPermissionMigration, verifyProtocolPermissions } from "../../scripts/governance/permissions";
import { setBridgeTokenFlowConfig } from "../../scripts/governance/bridgeFlowConfig";
import { rescueBridgeFunds } from "../../scripts/upgrade/rescueBridgeFunds";
import initializeBridgeFlowLimits from "../../deploy/003b_initialize_bridge_flow_limits";
import { upgradeBridge } from "../../scripts/upgrade/bridge";
import { forceSetState } from "../../scripts/upgrade/forceSetState";
import { UPGRADEABLE_CONTRACTS, upgradeAllContracts } from "../../scripts/upgrade/utils";
import { getDeployedContract } from "../../helpers/contracts-helpers";
import {
  defaultFlowConfig,
  ensureHardhatDeploymentChainId,
  getChecksumAddress,
  hexDataSlice,
  hexZeroPad,
  tokenSetHash,
  readStorageAt,
} from "./helpers/deploySystem";

const OWNABLES = [
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
const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function implementationOf(proxy: string): Promise<string> {
  return getChecksumAddress(hexDataSlice(await readStorageAt(proxy, IMPLEMENTATION_SLOT), 12));
}

function stringConfig(overrides: Record<string, unknown> = {}) {
  return Object.fromEntries(
    Object.entries({ ...defaultFlowConfig(overrides), totalWithdrawalCap: overrides.totalWithdrawalCap ?? 18_446_744_069_414_584_320n })
      .map(([key, value]) => [key, typeof value === "boolean" ? value : value.toString()]),
  );
}

function writeManifest(token: string, config: Record<string, unknown>, historicalWithdrawalTotal = "0"): { dir: string; file: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psy-flow-config-"));
  const file = path.join(dir, "manifest.json");
  fs.writeFileSync(file, JSON.stringify({
    tokens: [token], configs: [config], historicalWithdrawalTotals: [historicalWithdrawalTotal],
  }));
  return { dir, file };
}

describe("governance scripts local integration", function () {
  this.timeout(120000);

  beforeEach(async function () {
    await ensureHardhatDeploymentChainId();
    process.env.PSY_SKIP_BRIDGE_FLOW_LIMITS = "1";
    await deployments.fixture(["token_faucet"]);
  });

  it("initializes local Bridge flow policies for native and deployed tokens", async function () {
    delete process.env.PSY_SKIP_BRIDGE_FLOW_LIMITS;
    await initializeBridgeFlowLimits(hre);
    const bridge = await getDeployedContract("Bridge");
    const psy = await getDeployedContract("PsyToken");
    const usdt = await getDeployedContract("USDTToken");

    for (const token of [ethers.constants.AddressZero, psy.address, usdt.address]) {
      const config = await bridge.getTokenFlowConfig(token);
      expect(config.configured).to.equal(true);
      expect(config.minDepositAmount).to.equal(1);
    }
  });

  afterEach(function () {
    for (const name of [
      "PSY_SKIP_BRIDGE_FLOW_LIMITS",
      "BRIDGE_FLOW_LIMITS_FILE",
      "RESCUE_MODE",
      "BRIDGE_V3_FLOW_TOKENS",
      "RESCUE_TOKEN",
      "RESCUE_TO",
      "RESCUE_AMOUNT",
      "EXPECTED_LAST_FINALIZED_CHECKPOINT_ID",
      "EXPECTED_LAST_VERIFIED_CHECKPOINT_ROOT",
      "EXPECTED_LAST_VERIFIED_DEPOSIT_TREE_ROOT",
      "EXPECTED_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT",
      "EXPECTED_WITHDRAWAL_SUBTREE_ROOT",
      "NEW_LAST_FINALIZED_CHECKPOINT_ID",
      "NEW_LAST_VERIFIED_CHECKPOINT_ROOT",
      "NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT",
      "NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT",
      "NEW_WITHDRAWAL_SUBTREE_ROOT",
    ]) delete process.env[name];
  });

  it("runs the complete proxy upgrade set and force-state recovery script", async function () {
    const token = await getDeployedContract("USDTToken");
    const bridge = await getDeployedContract("Bridge");
    const timelock = await deployments.get("ExecutorWithTimelock");
    await bridge.initializeFlowLimits([token.address], [defaultFlowConfig()]);
    const bridgeInitData = bridge.interface.encodeFunctionData("initializeWithdrawalTotals", [
      [token.address],
      [defaultFlowConfig()],
      [0],
      tokenSetHash([token.address]),
      timelock.address,
    ]);
    const before = new Map<string, string>();
    for (const name of UPGRADEABLE_CONTRACTS) {
      const proxy = await deployments.get(`${name}_Proxy`);
      before.set(name, await implementationOf(proxy.address));
    }
    await upgradeAllContracts(undefined, bridgeInitData);
    for (const name of UPGRADEABLE_CONTRACTS) {
      const proxy = await deployments.get(`${name}_Proxy`);
      expect(await implementationOf(proxy.address)).to.not.equal(before.get(name));
    }

    const stateManager = await getDeployedContract("StateManager");
    process.env.EXPECTED_LAST_FINALIZED_CHECKPOINT_ID = String(await stateManager.lastFinalizedCheckpointId());
    process.env.EXPECTED_LAST_VERIFIED_CHECKPOINT_ROOT = await stateManager.lastVerifiedCheckpointRoot();
    process.env.EXPECTED_LAST_VERIFIED_DEPOSIT_TREE_ROOT = await stateManager.lastVerifiedDepositTreeRoot();
    process.env.EXPECTED_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT = await stateManager.lastVerifiedWithdrawalTreeRoot();
    process.env.EXPECTED_WITHDRAWAL_SUBTREE_ROOT = await stateManager.withdrawalSubtreeRoot();
    process.env.NEW_LAST_FINALIZED_CHECKPOINT_ID = process.env.EXPECTED_LAST_FINALIZED_CHECKPOINT_ID;
    process.env.NEW_LAST_VERIFIED_CHECKPOINT_ROOT = hexZeroPad("0x11", 32);
    process.env.NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT = hexZeroPad("0x12", 32);
    process.env.NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT = hexZeroPad("0x14", 32);
    process.env.NEW_WITHDRAWAL_SUBTREE_ROOT = hexZeroPad("0x15", 32);
    await forceSetState();
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(process.env.NEW_LAST_FINALIZED_CHECKPOINT_ID);
    expect(await stateManager.lastVerifiedCheckpointRoot()).to.equal(hexZeroPad("0x11", 32));
  });

  it("runs atomic Bridge upgrade, one-token config update, and all rescue modes", async function () {
    const [, recipient] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Rescue", "RSC");
    await token.deployed();
    const initial = writeManifest(token.address, stringConfig({ minDepositAmount: 10 }), "321");
      process.env.BRIDGE_V3_FLOW_TOKENS = JSON.stringify([token.address]);
    const bridgeBeforeUpgrade = await getDeployedContract("Bridge");
    await bridgeBeforeUpgrade.initializeFlowLimits([token.address], [defaultFlowConfig({ minDepositAmount: 10 })]);
    try {
      process.env.BRIDGE_FLOW_LIMITS_FILE = initial.file;
      await upgradeBridge();
      const bridge = await getDeployedContract("Bridge");
      expect((await bridge.getTokenFlowConfig(token.address)).minDepositAmount).to.equal(10);
      expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(321);

      const next = writeManifest(token.address, stringConfig({ minDepositAmount: 20 }));
      try {
        const update = await setBridgeTokenFlowConfig(token.address, next.file);
        expect(update.expectedConfigHash).to.not.equal(ethers.constants.HashZero);
        expect(await bridge.getTokenFlowConfigHash(token.address)).to.equal(update.nextConfigHash);
      } finally {
        fs.rmSync(next.dir, { recursive: true, force: true });
      }

      await token.mint(bridge.address, 1000);
      process.env.RESCUE_MODE = "erc20";
      process.env.RESCUE_TOKEN = token.address;
      process.env.RESCUE_TO = recipient.address;
      process.env.RESCUE_AMOUNT = "1000";
      const erc20Result = await rescueBridgeFunds();
      expect(erc20Result.pauseData).to.not.equal(undefined);
      expect(await token.balanceOf(recipient.address)).to.equal(1000);
      expect((await bridge.getPauseFlags(ethers.constants.AddressZero)).globalFlags).to.equal(7);

      await recipient.sendTransaction({ to: bridge.address, value: 1234 });
      process.env.RESCUE_MODE = "native";
      process.env.RESCUE_AMOUNT = "1234";
      const nativeBefore = await ethers.provider.getBalance(recipient.address);
      await rescueBridgeFunds();
      expect((await ethers.provider.getBalance(recipient.address)).sub(nativeBefore)).to.equal(1234);

      const weth = await getDeployedContract("WETH9");
      await weth.deposit({ value: 4321 });
      await weth.transfer(bridge.address, 4321);
      process.env.RESCUE_MODE = "weth-native";
      process.env.RESCUE_AMOUNT = "4321";
      const wethBefore = await ethers.provider.getBalance(recipient.address);
      await rescueBridgeFunds();
      expect((await ethers.provider.getBalance(recipient.address)).sub(wethBefore)).to.equal(4321);
    } finally {
      fs.rmSync(initial.dir, { recursive: true, force: true });
    }
  });

  it("runs the complete permission migration and verifies every deployed ownership boundary", async function () {
    const [currentSafe] = await ethers.getSigners();
    const acl = await getDeployedContract("PsyACLManager");
    const timelock = await getDeployedContract("ExecutorWithTimelock");
    const ownables = await Promise.all(OWNABLES.map(async (name) => ({
      name,
      contract: await getDeployedContract(name),
    })));
    const operations = await buildPermissionMigration({
      acl,
      timelockAddress: timelock.address,
      governanceSafe: currentSafe.address,
      ownables,
      legacyAccounts: [currentSafe.address],
    });
    expect(operations.length).to.be.greaterThan(10);
    for (const operation of operations) {
      await currentSafe.sendTransaction({ to: operation.target, data: operation.data });
    }

    await verifyProtocolPermissions(currentSafe.address);
    expect(await buildPermissionMigration({
      acl,
      timelockAddress: timelock.address,
      governanceSafe: currentSafe.address,
      ownables,
      legacyAccounts: [currentSafe.address],
    })).to.deep.equal([]);
  });
});
