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
import { forceSetState, revokeCheckpointTreeRoots, revokeKnownSubtreeRoots, setCheckpointTreeRootsClean } from "../../scripts/upgrade/forceSetState";
import { UPGRADEABLE_CONTRACTS, upgradeAllContracts, upgradeContract } from "../../scripts/upgrade/utils";
import { upgradeStateManager } from "../../scripts/upgrade/stateManager";
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
      "BRIDGE_GOVERNANCE_FLOW_TOKENS",
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

  it("blocks incompatible StateManager upgrades before side effects and retains force-state recovery", async function () {
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
    const blocked = "StateManager in-place upgrade is blocked";
    await expect(upgradeAllContracts(undefined, bridgeInitData)).to.be.rejectedWith(blocked);
    await expect(upgradeContract("StateManager")).to.be.rejectedWith(blocked);
    await expect(upgradeStateManager()).to.be.rejectedWith(blocked);
    await expect(hre.run("upgrade", { contract: "StateManager" })).to.be.rejectedWith(blocked);
    await expect(hre.run("upgrade:state-manager")).to.be.rejectedWith(blocked);
    for (const name of UPGRADEABLE_CONTRACTS) {
      const proxy = await deployments.get(`${name}_Proxy`);
      expect(await implementationOf(proxy.address)).to.equal(before.get(name));
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

  it("revokes named checkpoint tree roots and explicitly re-enables finalization", async function () {
    const stateManager = await getDeployedContract("StateManager");
    const provider = await getDeployedContract("PsyAddressesProvider");
    const acl = await getDeployedContract("PsyACLManager");
    const [admin] = await ethers.getSigners();
    await acl.grantRole(await acl.PROPOSER_ROLE(), admin.address);
    const verifier = await (await ethers.getContractFactory("MockGnarkVerifier")).deploy();
    await verifier.deployed();
    await provider.setAddress(await provider.ZK_VERIFIER_ID(), verifier.address);
    const zero = ethers.constants.HashZero;
    const root = hexZeroPad("0xa1", 32);
    const nextRoot = hexZeroPad("0xa2", 32);
    const proof = ethers.utils.defaultAbiCoder.encode(["uint256[8]"], [[1, 2, 3, 4, 5, 6, 7, 8]]);
    const merklePath = Array(9).fill(zero);
    const chainIndex = await stateManager.l1ChainIndex();
    await stateManager.finalize(proof, zero, [zero, root], zero, chainIndex, 1, merklePath, merklePath);
    await stateManager.finalize(proof, zero, [root, nextRoot], zero, chainIndex, 11, merklePath, merklePath);
    const expected = [11, nextRoot, zero, zero, zero];
    const replacement = hexZeroPad("0xb5", 32);
    const target = [5, replacement, zero, zero, zero];
    await stateManager.forceSetState(expected, target);
    await hre.run("state-manager:revoke-checkpoint-tree-roots", { rootsJson: JSON.stringify([nextRoot]) });
    expect(await stateManager.checkpointTreeRootsClean()).to.equal(false);
    expect(await stateManager.checkpointTreeRootCheckpointId(nextRoot)).to.equal(0);
    const cleanup = await revokeCheckpointTreeRoots([nextRoot]);
    expect(cleanup.data).to.equal(stateManager.interface.encodeFunctionData("revokeCheckpointTreeRoots", [[nextRoot]]));
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psy-checkpoint-roots-"));
    try {
      const file = path.join(dir, "roots.json");
      fs.writeFileSync(file, JSON.stringify([nextRoot]));
      await revokeCheckpointTreeRoots(file);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    expect(await stateManager.checkpointTreeRootCheckpointId(root)).to.equal(1);
    expect(await stateManager.checkpointTreeRootsClean()).to.equal(false);
    await expect(stateManager.finalize(proof, zero, [replacement, nextRoot], zero, chainIndex, 12, merklePath, merklePath))
      .to.be.revertedWithCustomError(stateManager, "CheckpointTreeRootCleanupRequired");
    await hre.run("state-manager:set-checkpoint-tree-roots-clean", { clean: true });
    expect(await stateManager.checkpointTreeRootsClean()).to.equal(true);
    await stateManager.finalize(proof, zero, [replacement, nextRoot], zero, chainIndex, 12, merklePath, merklePath);
    expect(await stateManager.checkpointTreeRootCheckpointId(root)).to.equal(1);
    expect(await stateManager.checkpointTreeRootCheckpointId(nextRoot)).to.equal(12);
    const paused = await setCheckpointTreeRootsClean(false);
    expect(paused.data).to.equal(stateManager.interface.encodeFunctionData("setCheckpointTreeRootsClean", [false]));
    expect(await stateManager.checkpointTreeRootsClean()).to.equal(false);
  });

  it("revokes named subtree memberships through JSON file and inline governance inputs", async function () {
    const stateManager = await getDeployedContract("StateManager");
    const zero = ethers.constants.HashZero;
    expect(await stateManager.knownDepositSubtreeRoots(zero)).to.equal(true);
    expect(await stateManager.knownWithdrawalSubtreeRoots(zero)).to.equal(true);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psy-subtree-roots-"));
    try {
      const file = path.join(dir, "roots.json");
      fs.writeFileSync(file, JSON.stringify([zero]));
      await hre.run("state-manager:revoke-known-subtree-roots", {
        depositRootsJson: file, withdrawalRootsJson: "[]",
      });
      expect(await stateManager.knownDepositSubtreeRoots(zero)).to.equal(false);
      expect(await stateManager.knownWithdrawalSubtreeRoots(zero)).to.equal(true);
      const revoked = await revokeKnownSubtreeRoots([], file);
      expect(revoked.data).to.equal(stateManager.interface.encodeFunctionData("revokeKnownSubtreeRoots", [[], [zero]]));
      await revokeKnownSubtreeRoots(JSON.stringify([zero]), [zero]);
      expect(await stateManager.knownWithdrawalSubtreeRoots(zero)).to.equal(false);
      expect(await stateManager.withdrawalSubtreeRoot()).to.equal(zero);
      expect(await stateManager.checkpointTreeRootsClean()).to.equal(true);
      await expect(revokeKnownSubtreeRoots(["0x01"], [])).to.be.rejectedWith("depositRootsJson");
      await expect(revokeKnownSubtreeRoots([], ["0x01"])).to.be.rejectedWith("withdrawalRootsJson");
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rejects invalid named roots before deployment lookup", async function () {
    for (const roots of [[ethers.constants.HashZero], ["0x01"], [1], {}]) {
      await expect(revokeCheckpointTreeRoots(JSON.stringify(roots))).to.be.rejected;
    }
  });

  it("runs atomic Bridge upgrade, one-token config update, and all rescue modes", async function () {
    const [, recipient] = await ethers.getSigners();
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Rescue", "RSC");
    await token.deployed();
    const initial = writeManifest(token.address, stringConfig({ minDepositAmount: 10 }), "321");
      process.env.BRIDGE_GOVERNANCE_FLOW_TOKENS = JSON.stringify([token.address]);
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

  it("orders the executing Safe's DEFAULT_ADMIN revocation last regardless of input order", async function () {
    const [safe, other] = await ethers.getSigners();
    const acl = await getDeployedContract("PsyACLManager");
    const timelock = await getDeployedContract("ExecutorWithTimelock");
    const defaultAdminRole = await acl.DEFAULT_ADMIN_ROLE();
    await acl.grantRole(defaultAdminRole, other.address);
    const operations = await buildPermissionMigration({
      acl,
      timelockAddress: timelock.address,
      governanceSafe: safe.address,
      ownables: [],
      stripAdmins: [safe.address, other.address],
    });
    expect(operations.length).to.be.greaterThan(0);
    const lastOperation = operations[operations.length - 1];
    const decoded = acl.interface.decodeFunctionData("revokeRole", lastOperation.data);
    expect(lastOperation.target).to.equal(acl.address);
    expect(decoded.role).to.equal(defaultAdminRole);
    expect(decoded.account).to.equal(safe.address);
  });

  it("runs the complete permission migration and verifies every deployed ownership boundary", async function () {
    const [currentSafe, proposerBot] = await ethers.getSigners();
    const acl = await getDeployedContract("PsyACLManager");
    const timelock = await getDeployedContract("ExecutorWithTimelock");
    const ownables = await Promise.all(OWNABLES.map(async (name) => ({
      name,
      contract: await getDeployedContract(name),
    })));
    // PROPOSER_ROLE is an operational bot role kept out of the governance cutover: move it from
    // the replaced admin onto a dedicated bot address while the Safe still holds DEFAULT_ADMIN_ROLE.
    const proposerRole = await acl.PROPOSER_ROLE();
    await acl.grantRole(proposerRole, proposerBot.address);
    await acl.revokeRole(proposerRole, currentSafe.address);
    const operations = await buildPermissionMigration({
      acl,
      timelockAddress: timelock.address,
      governanceSafe: currentSafe.address,
      ownables,
      stripAdmins: [currentSafe.address],
    });
    expect(operations.length).to.be.greaterThan(10);
    for (const operation of operations) {
      await currentSafe.sendTransaction({ to: operation.target, data: operation.data });
    }

    await verifyProtocolPermissions(currentSafe.address, proposerBot.address);
    await expect(verifyProtocolPermissions(currentSafe.address)).to.be.rejectedWith("proposer must be configured");
    await expect(verifyProtocolPermissions(currentSafe.address, currentSafe.address)).to.be.rejectedWith(
      "proposer must not be the Governance Safe"
    );
    expect(await buildPermissionMigration({
      acl,
      timelockAddress: timelock.address,
      governanceSafe: currentSafe.address,
      ownables,
      stripAdmins: [currentSafe.address],
    })).to.deep.equal([]);
  });
});
