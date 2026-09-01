import { expect } from "chai";
import { ethers, network } from "hardhat";
import {
  configureFlowToken,
  defaultFlowConfig,
  deployCoreSystem,
  tokenSetHash,
} from "./helpers/deploySystem";
import { DUMMY_GNARK_PROOF } from "./helpers/mockProof";
import { buildWithdrawalBatchClaimSingle } from "./helpers/withdrawalClaim";

function mkTopProof(leaf: string, index: number): { proof: string[]; root: string } {
  const proof = new Array(9).fill(ethers.constants.HashZero);
  proof[0] = leaf;
  let cur = leaf;
  for (let i = 0; i < 8; i++) {
    const sibling = ethers.utils.keccak256(
      ethers.utils.solidityPack(["string", "uint8"], ["flow-limit-sibling", i]),
    );
    proof[i + 1] = sibling;
    cur = ((index >> i) & 1) === 0
      ? ethers.utils.keccak256(ethers.utils.solidityPack(["bytes32", "bytes32"], [cur, sibling]))
      : ethers.utils.keccak256(ethers.utils.solidityPack(["bytes32", "bytes32"], [sibling, cur]));
  }
  return { proof, root: cur };
}

async function registerWithdrawal(params: {
  bridge: any;
  stateManager: any;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
}) {
  const { bridge, stateManager, recipient, token, amount, nonce } = params;
  const deposit = mkTopProof(await stateManager.withdrawalSubtreeRoot(), 0);
  const withdrawal = mkTopProof(ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32), 0);
  const lastCheckpointId = await stateManager.lastFinalizedCheckpointId();
  const previousCheckpointRoot = await stateManager.lastVerifiedCheckpointRoot();
  const nextCheckpointRoot = ethers.utils.keccak256(
    ethers.utils.solidityPack(["string", "uint256"], ["withdrawal-cap-checkpoint", nonce]),
  );
  await stateManager.finalize(
    DUMMY_GNARK_PROOF,
    deposit.root,
    [previousCheckpointRoot, nextCheckpointRoot],
    withdrawal.root,
    0,
    lastCheckpointId.add(1),
    deposit.proof,
    withdrawal.proof,
  );
  const calldata = buildWithdrawalBatchClaimSingle({
    withdrawalRoot: withdrawal.proof[0],
    recipient,
    token,
    amount,
    nonce,
    destinationChainIndex: 0,
  });
  await bridge.batchClaimWithdrawal(new Array(8).fill(0n), calldata.publicInputs, calldata.slotData);
  return ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32);
}

describe("Bridge per-token flow limits", function () {
  it("enforces deposit min, bucket, custody accounting, and token isolation", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, router, erc20Gateway } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockERC20");
    const tokenA = await factory.deploy("Token A", "A");
    const tokenB = await factory.deploy("Token B", "B");
    await tokenA.deployed();
    await tokenB.deployed();

    for (const token of [tokenA, tokenB]) {
      await router.setTokenMapping(token.address, ethers.utils.hexZeroPad(token.address, 32));
      await configureFlowToken(bridge, token.address, {
        minDepositAmount: 100,
        depositBucketCapacity: 500,
        depositRefillPerSecond: 10,
        custodyCap: 2_000,
      });
      await token.mint(user.address, 2_000);
      await token.connect(user).approve(erc20Gateway.address, 2_000);
    }

    // There is no per-transaction maximum: the deposit may use all currently
    // available bucket credit, subject to the custody cap.
    await router.connect(user).deposit(tokenA.address, 450, ethers.constants.HashZero, ethers.constants.HashZero);
    await expect(
      router.connect(user).deposit(tokenA.address, 100, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(bridge, "DepositRateLimited");
    expect(await tokenA.balanceOf(bridge.address)).to.equal(450);

    await expect(
      router.connect(user).deposit(tokenB.address, 99, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(bridge, "DepositBelowMinimum");
    await router.connect(user).deposit(tokenB.address, 250, ethers.constants.HashZero, ethers.constants.HashZero);
    expect(await tokenB.balanceOf(bridge.address)).to.equal(250);
  });

  it("updates a token config with stale-hash protection and without gifting quota", async function () {
    const [owner] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);
    const token = ethers.Wallet.createRandom().address;
    await configureFlowToken(bridge, token, {
      depositBucketCapacity: 500,
      depositRefillPerSecond: 1,
    });

    const oldHash = await bridge.getTokenFlowConfigHash(token);
    const before = (await bridge.getMaterializedDepositBucket(token)).available;
    const next = defaultFlowConfig({
      depositBucketCapacity: 1_000,
      depositRefillPerSecond: 1,
    });
    await bridge.setTokenFlowConfig(token, next, oldHash);
    const after = (await bridge.getMaterializedDepositBucket(token)).available;
    expect(after).to.be.lte(before.add(2));
    expect(after).to.be.lt(1_000);
    await expect(bridge.setTokenFlowConfig(token, next, oldHash)).to.be.revertedWithCustomError(
      bridge,
      "StaleConfigHash",
    );
  });

  it("rejects fee-on-transfer deposits without recording custody or a leaf", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, router, erc20Gateway } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockFeeOnTransferERC20");
    const token = await factory.deploy();
    await token.deployed();
    await router.setTokenMapping(token.address, ethers.utils.hexZeroPad(token.address, 32));
    await configureFlowToken(bridge, token.address);
    await token.mint(user.address, 1_000);
    await token.connect(user).approve(erc20Gateway.address, 1_000);

    await expect(
      router.connect(user).deposit(token.address, 100, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(erc20Gateway, "UnsupportedTokenTransfer");
    expect(await token.balanceOf(bridge.address)).to.equal(0);
    expect(await bridge.pendingDepositCount()).to.equal(0);
  });

  it("accumulates lifetime registered volume across pending and settled withdrawals without decrementing", async function () {
    const [owner, recipient, keeper] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 100,
      lifetimeWithdrawalThreshold: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 0,
      thresholdExceededWithdrawalDelay: 3_600,
    });
    await token.mint(bridge.address, 601);

    const firstNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 300n, nonce: 9001n,
    });
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(300);
    await bridge.connect(keeper).claimPendingWithdrawal(firstNonce);
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(300);

    const secondNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 200n, nonce: 9002n,
    });
    expect((await bridge.pendingWithdrawals(secondNonce)).amount).to.equal(200);
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(500);

    const crossingPreview = await bridge.previewWithdrawal(token.address, 1);
    expect(crossingPreview.currentTotalRegisteredAmount).to.equal(500);
    expect(crossingPreview.projectedTotalRegisteredAmount).to.equal(501);
    expect(crossingPreview.tier).to.equal(2);
    const crossingNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 1n, nonce: 9003n,
    });
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(501);
    expect((await bridge.pendingWithdrawals(crossingNonce)).claimableAt).to.be.gt(
      (await ethers.provider.getBlock("latest")).timestamp,
    );
    expect((await bridge.previewWithdrawal(token.address, 1)).tier).to.equal(2);
  });

  it("lets only the initialized Timelock executor force-claim the exact stored withdrawal", async function () {
    const [owner, recipient, other] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 10,
      lifetimeWithdrawalThreshold: 20,
      thresholdExceededWithdrawalDelay: 3_600,
    });
    const timelock = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(
      owner.address, 1, 100, 1, 100,
    );
    await timelock.deployed();
    await bridge.initializeWithdrawalTotals(
      [token.address], [0], tokenSetHash([token.address]), timelock.address,
    );
    expect(await bridge.withdrawalForceClaimExecutor()).to.equal(timelock.address);
    expect(await bridge.withdrawalTotalsTokenSetHash()).to.equal(tokenSetHash([token.address]));
    await token.mint(bridge.address, 30);
    const nonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 30n, nonce: 0xa1n,
    });

    for (const caller of [owner, other]) {
      await expect(bridge.connect(caller).forceClaimWithdrawal(nonce))
        .to.be.revertedWithCustomError(bridge, "UnauthorizedWithdrawalForceClaimExecutor")
        .withArgs(caller.address);
    }
    await bridge.setTokenPauseFlags(token.address, 4);
    const data = bridge.interface.encodeFunctionData("forceClaimWithdrawal", [nonce]);
    let executionTime = (await ethers.provider.getBlock("latest")).timestamp + 2;
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime, false);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime, false))
      .to.be.revertedWith("FAILED_ACTION_EXECUTION");
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(30);

    await bridge.setTokenPauseFlags(token.address, 0);
    executionTime = (await ethers.provider.getBlock("latest")).timestamp + 2;
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime, false);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime, false))
      .to.emit(bridge, "WithdrawalForceClaimed")
      .withArgs(nonce, timelock.address);
    expect(await token.balanceOf(recipient.address)).to.equal(30);
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(30);
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(0);
  });

  it("uses lifetime totals for tiering, isolates tokens, and applies governance cap changes prospectively", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockERC20");
    const tokenA = await factory.deploy("Token A", "A");
    const tokenB = await factory.deploy("Token B", "B");
    await tokenA.deployed();
    await tokenB.deployed();
    for (const token of [tokenA, tokenB]) {
      await configureFlowToken(bridge, token.address, {
        smallWithdrawalMax: 100,
        lifetimeWithdrawalThreshold: 200,
        smallWithdrawalDelay: 0,
        mediumWithdrawalDelay: 0,
        thresholdExceededWithdrawalDelay: 3_600,
      });
    }

    await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: tokenA.address, amount: 100n, nonce: 0x11n,
    });
    const atCap = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: tokenA.address, amount: 100n, nonce: 0x22n,
    });
    expect((await bridge.pendingWithdrawals(atCap)).claimableAt).to.be.lte((await ethers.provider.getBlock("latest")).timestamp);
    expect((await bridge.previewWithdrawal(tokenA.address, 1)).tier).to.equal(2);
    expect((await bridge.previewWithdrawal(tokenB.address, 1)).tier).to.equal(0);
    expect(await bridge.totalRegisteredWithdrawalAmount(tokenB.address)).to.equal(0);

    const oldHash = await bridge.getTokenFlowConfigHash(tokenA.address);
    await bridge.setTokenFlowConfig(tokenA.address, defaultFlowConfig({
      smallWithdrawalMax: 100,
      lifetimeWithdrawalThreshold: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 0,
      thresholdExceededWithdrawalDelay: 3_600,
    }), oldHash);
    expect(await bridge.totalRegisteredWithdrawalAmount(tokenA.address)).to.equal(200);
    expect((await bridge.previewWithdrawal(tokenA.address, 50)).tier).to.equal(0);
  });

  it("keeps pause state outside the config hash and gives Guardian pause-only behavior", async function () {
    const [owner, guardian] = await ethers.getSigners();
    const { bridge, acl } = await deployCoreSystem(owner.address, owner.address);
    const token = ethers.Wallet.createRandom().address;
    await configureFlowToken(bridge, token);
    await acl.grantRole(await acl.GUARDIAN_ROLE(), guardian.address);

    const configHash = await bridge.getTokenFlowConfigHash(token);
    await bridge.connect(guardian).guardianPauseToken(token, 1);
    expect(await bridge.getTokenFlowConfigHash(token)).to.equal(configHash);
    expect((await bridge.getPauseFlags(token)).effectiveFlags).to.equal(1);

    await bridge.connect(guardian).guardianPauseToken(token, 0);
    expect((await bridge.getPauseFlags(token)).effectiveFlags).to.equal(1);
    await expect(bridge.connect(guardian).setTokenPauseFlags(token, 0)).to.be.revertedWithCustomError(
      bridge,
      "UnauthorizedBridgeAdmin",
    );
    await bridge.setTokenPauseFlags(token, 0);
    expect((await bridge.getPauseFlags(token)).effectiveFlags).to.equal(0);
  });
  it("rolls lifetime totals and nullifiers back when the batch commit check fails after registration", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);

    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0xbeef", 32), 0);
    const deposit = mkTopProof(await stateManager.withdrawalSubtreeRoot(), 0);
    await stateManager.finalize(
      DUMMY_GNARK_PROOF,
      deposit.root,
      [await stateManager.lastVerifiedCheckpointRoot(), ethers.utils.hexZeroPad("0x42", 32)],
      withdrawal.root,
      0,
      (await stateManager.lastFinalizedCheckpointId()).add(1),
      deposit.proof,
      withdrawal.proof,
    );
    const nonce = 0x77n;
    const calldata = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawal.proof[0], recipient: recipient.address, token: token.address,
      amount: 123n, nonce, destinationChainIndex: 0,
    });
    calldata.publicInputs[10] ^= 1n;
    await expect(bridge.batchClaimWithdrawal(new Array(8).fill(0n), calldata.publicInputs, calldata.slotData))
      .to.be.revertedWithCustomError(bridge, "InvalidWithdrawalProof");
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(0);
    expect(await bridge.claimedNullifiers(ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32))).to.equal(false);
  });


  it("enforces Goldilocks bounds and rolls lifetime totals and nullifiers back on failed registration", async function () {
    const GOLDILOCKS_PRIME = 18_446_744_069_414_584_321n;
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 5, lifetimeWithdrawalThreshold: 10 });

    const validPreview = await bridge.previewWithdrawal(token.address, GOLDILOCKS_PRIME - 1n);
    expect(validPreview.status).to.equal(0);
    expect(validPreview.currentTotalRegisteredAmount).to.equal(0);
    expect(validPreview.projectedTotalRegisteredAmount).to.equal(GOLDILOCKS_PRIME - 1n);
    expect((await bridge.previewWithdrawal(token.address, GOLDILOCKS_PRIME)).status).to.equal(3);

    await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address,
      amount: GOLDILOCKS_PRIME - 1n, nonce: 0x97n,
    });
    expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(GOLDILOCKS_PRIME - 1n);
    for (const [amount, nonce] of [
      [GOLDILOCKS_PRIME, 0x94n],
      [GOLDILOCKS_PRIME + 1n, 0x95n],
      [(1n << 64n) - 1n, 0x96n],
    ] as const) {
      await expect(registerWithdrawal({
        bridge, stateManager, recipient: recipient.address, token: token.address, amount, nonce,
      })).to.be.revertedWithCustomError(bridge, "InvalidWithdrawalAmount").withArgs(amount);
      expect(await bridge.claimedNullifiers(ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32))).to.equal(false);
      expect(await bridge.totalRegisteredWithdrawalAmount(token.address)).to.equal(GOLDILOCKS_PRIME - 1n);
    }
  });
});
