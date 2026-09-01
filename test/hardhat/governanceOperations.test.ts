import { expect } from "chai";
import fs from "fs";
import os from "os";
import path from "path";
import { deployments, ethers, network } from "hardhat";
import { buildForceWithdrawalClaim, buildTokenFlowConfigUpdate } from "../../scripts/governance/bridgeFlowConfig";
import { buildPermissionMigration } from "../../scripts/governance/permissions";
import { decodeGovernanceTransaction, decodeSafeProposalFile } from "../../helpers/transaction-decoder";
import { getTimeLockData, getTimelockActionStatus } from "../../helpers/timelock-helpers";
import { buildSafeTransactionBuilderPayload } from "../../helpers/safe-helpers";
import { TimeLockOperation } from "../../helpers/hardhat-constants";
import { configureFlowToken, defaultFlowConfig, deployCoreSystem } from "./helpers/deploySystem";

describe("governance operation tooling", function () {
  it("builds and applies an ordered, idempotent permission migration", async function () {
    const [owner] = await ethers.getSigners();
    const { provider, acl, bridge } = await deployCoreSystem(owner.address, owner.address);
    const timelockFactory = await ethers.getContractFactory("ExecutorWithTimelock");
    const timelock = await timelockFactory.deploy(owner.address, 60, 120, 1, 3600);
    await timelock.deployed();
    const input = {
      acl,
      timelockAddress: timelock.address,
      governanceSafe: owner.address,
      ownables: [
        { name: "PsyAddressesProvider", contract: provider },
        { name: "PsyACLManager", contract: acl },
        { name: "Bridge", contract: bridge },
      ],
      legacyAccounts: [owner.address],
    };
    const operations = await buildPermissionMigration(input);
    expect(operations[0].description).to.equal("grant DEFAULT_ADMIN_ROLE to Timelock");
    expect(operations[operations.length - 1].description).to.contain("revoke DEFAULT_ADMIN_ROLE");
    for (const operation of operations) {
      await owner.sendTransaction({ to: operation.target, data: operation.data });
    }
    expect(await acl.hasRole(await acl.DEFAULT_ADMIN_ROLE(), timelock.address)).to.equal(true);
    expect(await acl.hasRole(await acl.DEFAULT_ADMIN_ROLE(), owner.address)).to.equal(false);
    expect(await acl.hasRole(await acl.GUARDIAN_ROLE(), owner.address)).to.equal(true);
    expect(await acl.hasRole(await acl.PROPOSER_ROLE(), owner.address)).to.equal(true);
    expect(await provider.owner()).to.equal(timelock.address);
    expect(await acl.owner()).to.equal(timelock.address);
    expect(await bridge.owner()).to.equal(timelock.address);
    expect(await buildPermissionMigration(input)).to.deep.equal([]);
  });

  it("rejects a permission batch when the Governance Safe cannot transfer an owner", async function () {
    const [owner, other] = await ethers.getSigners();
    const { acl, bridge } = await deployCoreSystem(owner.address, owner.address);
    let message = "";
    try {
      await buildPermissionMigration({
        acl,
        timelockAddress: ethers.Wallet.createRandom().address,
        governanceSafe: other.address,
        ownables: [{ name: "Bridge", contract: bridge }],
        legacyAccounts: [owner.address],
      });
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).to.contain("not Governance Safe");
  });

  it("builds a per-token config update using the current on-chain hash", async function () {
    const [owner] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);
    const token = ethers.Wallet.createRandom().address;
    await configureFlowToken(bridge, token);
    const config = Object.fromEntries(
      Object.entries(defaultFlowConfig({ minDepositAmount: 25, depositBucketCapacity: 2_000_000_000_000n }))
        .map(([key, value]) => [key, typeof value === "boolean" ? value : value.toString()]),
    ) as any;

    const update = await buildTokenFlowConfigUpdate(bridge, token, config);
    expect(update.expectedConfigHash).to.equal(await bridge.getTokenFlowConfigHash(token));
    const decoded = bridge.interface.decodeFunctionData("setTokenFlowConfig", update.data);
    expect(decoded.token).to.equal(token);
    expect(decoded.expectedConfigHash).to.equal(update.expectedConfigHash);
    expect(decoded.next.minDepositAmount).to.equal(25);

    await bridge.setTokenFlowConfig(decoded.token, decoded.next, decoded.expectedConfigHash);
    expect(await bridge.getTokenFlowConfigHash(token)).to.equal(update.nextConfigHash);
  });

  it("builds and decodes a governance pending-withdrawal claim", async function () {
    const [owner] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);
    const claim = buildForceWithdrawalClaim(bridge, "0x1234");
    const decoded = bridge.interface.decodeFunctionData("forceClaimWithdrawal", claim.data);
    expect(decoded.nonce).to.equal(ethers.utils.hexZeroPad("0x1234", 32));
    expect(decodeGovernanceTransaction(claim.target, claim.data).functionName)
      .to.equal("forceClaimWithdrawal");
  });

  it("round-trips a nested Timelock payload and Safe proposal file", async function () {
    const target = ethers.Wallet.createRandom().address;
    const timelock = ethers.Wallet.createRandom().address;
    const bridgeInterface = new ethers.utils.Interface(["function setGlobalPauseFlags(uint8 flags)"]);
    const timelockInterface = new ethers.utils.Interface([
      "function queueTransaction(address,uint256,string,bytes,uint256,bool)",
    ]);
    const innerData = bridgeInterface.encodeFunctionData("setGlobalPauseFlags", [7]);
    const outerData = timelockInterface.encodeFunctionData("queueTransaction", [
      target,
      0,
      "",
      innerData,
      1_900_000_000,
      false,
    ]);
    const decoded = decodeGovernanceTransaction(timelock, outerData);
    expect(decoded.functionName).to.equal("queueTransaction");
    expect(decoded.inner?.functionName).to.equal("setGlobalPauseFlags");
    expect(decoded.inner?.arguments).to.deep.equal([7]);
    expect(decoded.actionHash).to.match(/^0x[0-9a-f]{64}$/);

    const bridgeUpgradeInterface = new ethers.utils.Interface([
      "function initializeWithdrawalTotals(address[] configuredTokens,uint256[] historicalTotals,bytes32 expectedTokenSetHash,address forceClaimExecutor)",
    ]);
    const proxyAdminInterface = new ethers.utils.Interface([
      "function upgradeAndCall(address proxy,address implementation,bytes data)",
    ]);
    const initData = bridgeUpgradeInterface.encodeFunctionData("initializeWithdrawalTotals", [
      [target],
      [123],
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["address[]"], [[target]])),
      timelock,
    ]);
    const upgradeData = proxyAdminInterface.encodeFunctionData("upgradeAndCall", [
      target,
      ethers.Wallet.createRandom().address,
      initData,
    ]);
    expect(decodeGovernanceTransaction(timelock, upgradeData).inner?.functionName).to.equal("initializeWithdrawalTotals");

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psy-safe-proposal-"));
    const file = path.join(dir, "proposal.json");
    const safePayload = buildSafeTransactionBuilderPayload({
      safe: ethers.Wallet.createRandom().address,
      proposer: ethers.Wallet.createRandom().address,
      chainId: "1",
      networkName: "ethereum",
      transactions: [{ to: timelock, value: "0", data: outerData }],
      createdAt: 1_900_000_000_000,
    });
    expect(safePayload.version).to.equal("1.0");
    expect(safePayload.chainId).to.equal("1");
    expect(safePayload.transactions[0].contractMethod).to.equal(null);
    fs.writeFileSync(file, JSON.stringify(safePayload));
    try {
      const fromFile = decodeSafeProposalFile(file);
      expect(fromFile[0].actionHash).to.equal(decoded.actionHash);
      expect(fromFile[0].inner?.target).to.equal(target);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it("reports Timelock actions as not queued, waiting, ready, then expired", async function () {
    const [admin] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("ExecutorWithTimelock");
    const timelock = await factory.deploy(admin.address, 60, 120, 1, 3600);
    await timelock.deployed();
    const artifact = await deployments.getArtifact("ExecutorWithTimelock");
    await deployments.save("ExecutorWithTimelock", { address: timelock.address, abi: artifact.abi });
    const data = "0x12345678";
    const target = ethers.Wallet.createRandom().address;
    const block = await ethers.provider.getBlock("latest");
    const executionTime = String(block.timestamp + 70);

    let missingEtaError = "";
    try {
      await getTimeLockData(target, data, undefined, TimeLockOperation.Execute);
    } catch (error) {
      missingEtaError = (error as Error).message;
    }
    expect(missingEtaError).to.contain("reuse the exact queued ETA");
    let shortEtaError = "";
    try {
      await getTimeLockData(target, data, String(block.timestamp + 1), TimeLockOperation.Queue);
    } catch (error) {
      shortEtaError = (error as Error).message;
    }
    expect(shortEtaError).to.contain("below the current minimum");

    expect((await getTimelockActionStatus(target, data, executionTime)).state).to.equal("NotQueued");
    await timelock.queueTransaction(target, 0, "", data, executionTime, false);
    expect((await getTimelockActionStatus(target, data, executionTime)).state).to.equal("Waiting");
    await network.provider.send("evm_setNextBlockTimestamp", [Number(executionTime)]);
    await network.provider.send("evm_mine");
    expect((await getTimelockActionStatus(target, data, executionTime)).state).to.equal("Ready");
    await network.provider.send("evm_setNextBlockTimestamp", [Number(executionTime) + 121]);
    await network.provider.send("evm_mine");
    expect((await getTimelockActionStatus(target, data, executionTime)).state).to.equal("Expired");
  });

  it("rotates the Timelock admin through self-call nomination and new-admin acceptance", async function () {
    const [oldAdmin, newAdmin] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("ExecutorWithTimelock");
    const timelock = await factory.deploy(oldAdmin.address, 60, 120, 1, 3600);
    await timelock.deployed();
    const nominationData = timelock.interface.encodeFunctionData("setPendingAdmin", [newAdmin.address]);
    const block = await ethers.provider.getBlock("latest");
    const executionTime = block.timestamp + 61;
    await timelock.queueTransaction(timelock.address, 0, "", nominationData, executionTime, false);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await network.provider.send("evm_mine");
    await timelock.executeTransaction(timelock.address, 0, "", nominationData, executionTime, false);
    expect(await timelock.getPendingAdmin()).to.equal(newAdmin.address);
    await expect(timelock.acceptAdmin()).to.be.revertedWith("ONLY_BY_PENDING_ADMIN");
    await timelock.connect(newAdmin).acceptAdmin();
    expect(await timelock.getAdmin()).to.equal(newAdmin.address);
    expect(await timelock.getPendingAdmin()).to.equal(ethers.constants.AddressZero);
  });
});
