import { localFlowLimitConfig } from "../../deploy/003b_initialize_bridge_flow_limits";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import {
  configureFlowToken,
  defaultFlowConfig,
  deployCoreSystem,
  tokenSetHash,
} from "./helpers/deploySystem";
import { DUMMY_GNARK_PROOF } from "./helpers/mockProof";
import { buildWithdrawalBatchClaim, buildWithdrawalBatchClaimSingle } from "./helpers/withdrawalClaim";

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

const CLAIM_REASON = { AMOUNT_OUT_OF_RANGE: 8 } as const;


async function prepareWithdrawal(params: {
  bridge: any;
  stateManager: any;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
}) {
  const { stateManager, recipient, token, amount, nonce } = params;
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
  return {
    publicInputs: calldata.publicInputs,
    slotData: calldata.slotData,
    nonceHex: ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32),
  };
}

async function registerWithdrawal(params: {
  bridge: any;
  stateManager: any;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
}) {
  const { bridge } = params;
  const { publicInputs, slotData, nonceHex } = await prepareWithdrawal(params);
  await bridge.batchClaimWithdrawal(new Array(8).fill(0n), publicInputs, slotData);
  return nonceHex;
}

describe("Bridge per-token flow limits", function () {
  it("enforces deposit minimum, deposit cap, and token isolation", async function () {
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
        depositCap: 500,
      });
      await token.mint(user.address, 2_000);
      await token.connect(user).approve(erc20Gateway.address, 2_000);
    }

    await router.connect(user).deposit(tokenA.address, 400, ethers.constants.HashZero, ethers.constants.HashZero);
    await expect(
      router.connect(user).deposit(tokenA.address, 101, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(bridge, "DepositCapExceeded");
    expect(await tokenA.balanceOf(bridge.address)).to.equal(400);

    await expect(
      router.connect(user).deposit(tokenB.address, 99, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(bridge, "DepositBelowMinimum");
    await router.connect(user).deposit(tokenB.address, 250, ethers.constants.HashZero, ethers.constants.HashZero);
    expect(await tokenB.balanceOf(bridge.address)).to.equal(250);
  });

  it("updates a token config with stale-hash protection", async function () {
    const [owner] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);
    const token = ethers.Wallet.createRandom().address;
    await configureFlowToken(bridge, token, { depositCap: 500 });

    const oldHash = await bridge.getTokenFlowConfigHash(token);
    const next = defaultFlowConfig({ depositCap: 1_000 });
    await bridge.setTokenFlowConfig(token, next, oldHash);
    expect((await bridge.getTokenFlowConfig(token)).depositCap).to.equal(1_000);
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

  it("uses exact 50k/100k default boundaries and keeps the 10^12-token cap within uint128", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, localFlowLimitConfig(6));
    const quantities = [49_999_999_999n, 50_000_000_000n, 99_999_999_999n, 100_000_000_000n];
    await token.mint(bridge.address, quantities[0]);
    for (let index = 0; index < quantities.length; index++) {
      const nonce = await registerWithdrawal({ bridge, stateManager, recipient: recipient.address,
        token: token.address, amount: quantities[index], nonce: BigInt(0xe1 + index) });
      const pending = await bridge.pendingWithdrawals(nonce);
      expect(pending.amount).to.equal(index === 0 ? 0 : quantities[index]);
      expect(await bridge.withdrawalRequiresGovernance(nonce)).to.equal(index === 3);
      if (index > 0) expect(pending.claimableAt).to.equal((await ethers.provider.getBlock("latest")).timestamp + (index === 3 ? 604800 : 3600));
    }
    expect(await token.balanceOf(recipient.address)).to.equal(quantities[0]);
    for (const decimals of [6, 9, 18]) {
      await configureFlowToken(bridge, token.address, localFlowLimitConfig(decimals));
      expect((await bridge.getTokenFlowConfig(token.address)).totalWithdrawalCap).to.equal(10n ** BigInt(12 + decimals));
    }
  });

  it("pays small withdrawals directly and unlocks medium claims only after their stored delay", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 50_000, mediumWithdrawalMax: 100_000, totalWithdrawalCap: 1_000_000,
      mediumWithdrawalDelay: 3600, largeWithdrawalDelay: 604800,
    });
    await token.mint(bridge.address, 200_001);
    const small = await registerWithdrawal({ bridge, stateManager, recipient: recipient.address,
      token: token.address, amount: 50_000n, nonce: 0xb1n });
    expect(await token.balanceOf(recipient.address)).to.equal(50_000);
    expect((await bridge.pendingWithdrawals(small)).amount).to.equal(0);
    expect(await bridge.claimedNullifiers(small)).to.equal(true);
    const prepared = buildWithdrawalBatchClaimSingle({ withdrawalRoot: await stateManager.withdrawalSubtreeRoot(),
      recipient: recipient.address, token: token.address, amount: 50_000n, nonce: 0xb1n, destinationChainIndex: 0 });
    await expect(bridge.batchClaimWithdrawal(new Array(8).fill(0n), prepared.publicInputs, prepared.slotData))
      .to.emit(bridge, "WithdrawalClaimItemFailed").withArgs(small, 0, 5);
    expect(await token.balanceOf(recipient.address)).to.equal(50_000);
    const medium = await registerWithdrawal({ bridge, stateManager, recipient: recipient.address,
      token: token.address, amount: 50_001n, nonce: 0xb2n });
    const pending = await bridge.pendingWithdrawals(medium);
    expect(pending.claimableAt).to.equal((await ethers.provider.getBlock("latest")).timestamp + 3600);
    expect(await bridge.withdrawalRequiresGovernance(medium)).to.equal(false);
    await expect(bridge.connect(recipient).claimPendingWithdrawal(medium))
      .to.be.revertedWithCustomError(bridge, "PendingWithdrawalNotClaimable");
    await network.provider.send("evm_setNextBlockTimestamp", [pending.claimableAt.toNumber()]);
    await bridge.connect(recipient).claimPendingWithdrawal(medium);
    expect(await token.balanceOf(recipient.address)).to.equal(100_001);
    await expect(bridge.claimPendingWithdrawal(medium)).to.be.revertedWithCustomError(bridge, "PendingWithdrawalNotFound");
  });

  it("applies the cap to each slot in order and governs the crossing slot and every later slot", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 100, mediumWithdrawalMax: 200,
      totalWithdrawalCap: 100, mediumWithdrawalDelay: 3600, largeWithdrawalDelay: 604800 });
    await token.mint(bridge.address, 121);
    await prepareWithdrawal({ bridge, stateManager, recipient: recipient.address, token: token.address, amount: 60n, nonce: 0xc1n });
    const batch = buildWithdrawalBatchClaim({ withdrawalRoot: await stateManager.withdrawalSubtreeRoot(),
      items: [60n, 60n, 1n].map((amount, index) => ({ recipient: recipient.address, token: token.address,
        amount, nonce: BigInt(0xc1 + index), destinationChainIndex: 0 })) });
    await bridge.batchClaimWithdrawal(new Array(8).fill(0n), batch.publicInputs, batch.slotData);
    expect(await token.balanceOf(recipient.address)).to.equal(60);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(121);
    for (const nonce of ["0xc2", "0xc3"]) {
      const key = ethers.utils.hexZeroPad(nonce, 32);
      expect(await bridge.withdrawalRequiresGovernance(key)).to.equal(true);
      expect((await bridge.pendingWithdrawals(key)).claimableAt)
        .to.equal((await ethers.provider.getBlock("latest")).timestamp + 604800);
    }
  });

  it("blocks all withdrawal callbacks while a small native payout is executing", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager, weth } = await deployCoreSystem(owner.address, owner.address);
    await configureFlowToken(bridge, ethers.constants.AddressZero, { smallWithdrawalMax: 100, mediumWithdrawalMax: 200,
      totalWithdrawalCap: 1000, mediumWithdrawalDelay: 0 });
    await weth.deposit({ value: 210 });
    await weth.transfer(bridge.address, 210);
    const medium = await registerWithdrawal({ bridge, stateManager, recipient: recipient.address,
      token: ethers.constants.AddressZero, amount: 150n, nonce: 0xd1n });
    const callback = await (await ethers.getContractFactory("ReentrantWithdrawalRecipient")).deploy(bridge.address, medium);
    await callback.deployed();
    const prepared = await prepareWithdrawal({ bridge, stateManager, recipient: callback.address,
      token: ethers.constants.AddressZero, amount: 60n, nonce: 0xd2n });
    await callback.setBatchCallData(bridge.interface.encodeFunctionData("batchClaimWithdrawal", [
      new Array(8).fill(0n), prepared.publicInputs, prepared.slotData]));
    await bridge.batchClaimWithdrawal(new Array(8).fill(0n), prepared.publicInputs, prepared.slotData);
    expect(await ethers.provider.getBalance(callback.address)).to.equal(60);
    expect(await callback.pendingBlocked()).to.equal(true);
    expect(await callback.governanceBlocked()).to.equal(true);
    expect(await callback.batchBlocked()).to.equal(true);
    expect((await bridge.pendingWithdrawals(medium)).amount).to.equal(150);
    await bridge.claimPendingWithdrawal(medium);
    expect((await bridge.pendingWithdrawals(medium)).amount).to.equal(0);
  });

  it("accumulates lifetime withdrawal amount across pending and settled withdrawals without decrementing", async function () {
    const [owner, recipient, keeper] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 100,
      mediumWithdrawalMax: 300,
      totalWithdrawalCap: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 0,
      largeWithdrawalDelay: 3_600,
    });
    await token.mint(bridge.address, 601);

    const firstNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 300n, nonce: 9001n,
    });
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(300);
    await bridge.connect(keeper).claimPendingWithdrawal(firstNonce);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(300);

    const secondNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 200n, nonce: 9002n,
    });
    expect((await bridge.pendingWithdrawals(secondNonce)).amount).to.equal(200);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(500);

    const crossingNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address, amount: 1n, nonce: 9003n,
    });
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(501);
    expect((await bridge.pendingWithdrawals(crossingNonce)).claimableAt).to.be.gt(
      (await ethers.provider.getBlock("latest")).timestamp,
    );
  });

  it("lets only the initialized Timelock executor force-claim the exact stored withdrawal", async function () {
    const [owner, recipient, other] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    const config = await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 10,
      mediumWithdrawalMax: 20,
      totalWithdrawalCap: 20,
      largeWithdrawalDelay: 3_600,
    });
    const timelock = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(
      owner.address, 1, 100, 1, 100,
    );
    await timelock.deployed();
    await bridge.initializeWithdrawalTotals(
      [token.address], [config], [0], tokenSetHash([token.address]), timelock.address,
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
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime))
      .to.be.revertedWith("FAILED_ACTION_EXECUTION");
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(30);

    await bridge.setTokenPauseFlags(token.address, 0);
    executionTime = (await ethers.provider.getBlock("latest")).timestamp + 2;
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime))
      .to.be.revertedWith("FAILED_ACTION_EXECUTION");
    await expect(bridge.connect(recipient).claimPendingWithdrawal(nonce))
      .to.be.revertedWithCustomError(bridge, "WithdrawalGovernanceRequired");
    executionTime = (await bridge.pendingWithdrawals(nonce)).claimableAt.toNumber();
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime))
      .to.emit(bridge, "WithdrawalForceClaimed")
      .withArgs(nonce, timelock.address);
    expect(await token.balanceOf(recipient.address)).to.equal(30);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(30);
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(0);
  });

  it("uses total withdrawal cap for large delays and keeps token totals isolated", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockERC20");
    const tokenA = await factory.deploy("Token A", "A");
    const tokenB = await factory.deploy("Token B", "B");
    await tokenA.deployed();
    await tokenB.deployed();
    for (const token of [tokenA, tokenB]) {
      await token.mint(bridge.address, 1000);
      await configureFlowToken(bridge, token.address, {
        smallWithdrawalMax: 100,
        mediumWithdrawalMax: 150,
        totalWithdrawalCap: 200,
        smallWithdrawalDelay: 0,
        mediumWithdrawalDelay: 0,
        largeWithdrawalDelay: 3_600,
      });
    }

    await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: tokenA.address, amount: 100n, nonce: 0x11n,
    });
    const atCap = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: tokenA.address, amount: 100n, nonce: 0x22n,
    });
    expect((await bridge.pendingWithdrawals(atCap)).amount).to.equal(0);
    expect(await tokenA.balanceOf(recipient.address)).to.equal(200);
    const crossingNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: tokenA.address, amount: 1n, nonce: 0x33n,
    });
    expect((await bridge.pendingWithdrawals(crossingNonce)).claimableAt).to.be.gt(
      (await ethers.provider.getBlock("latest")).timestamp,
    );
    const tokenBNonce = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: tokenB.address, amount: 1n, nonce: 0x44n,
    });
    expect((await bridge.pendingWithdrawals(tokenBNonce)).amount).to.equal(0);
    expect(await tokenB.balanceOf(recipient.address)).to.equal(1);
    expect(await bridge.totalWithdrawalAmount(tokenB.address)).to.equal(1);

    const oldHash = await bridge.getTokenFlowConfigHash(tokenA.address);
    await bridge.setTokenFlowConfig(tokenA.address, defaultFlowConfig({
      smallWithdrawalMax: 100,
      mediumWithdrawalMax: 150,
      totalWithdrawalCap: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 0,
      largeWithdrawalDelay: 3_600,
    }), oldHash);
    expect(await bridge.totalWithdrawalAmount(tokenA.address)).to.equal(201);
    expect(await bridge.withdrawalRequiresGovernance(crossingNonce)).to.equal(true);
    await network.provider.send("evm_setNextBlockTimestamp", [(await bridge.pendingWithdrawals(crossingNonce)).claimableAt.toNumber()]);
    await expect(bridge.claimPendingWithdrawal(crossingNonce)).to.be.revertedWithCustomError(bridge, "WithdrawalGovernanceRequired");
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
  it("reverts the whole batch with zero effects when the batch commit check fails before registration", async function () {
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
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(0);
    expect(await bridge.claimedNullifiers(ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32))).to.equal(false);
  });


  it("skips Goldilocks-bound slots with reason 8 without consuming nullifiers or totals", async function () {
    const GOLDILOCKS_PRIME = 18_446_744_069_414_584_321n;
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 5,
      mediumWithdrawalMax: 10,
      totalWithdrawalCap: 10,
    });

    await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, token: token.address,
      amount: GOLDILOCKS_PRIME - 1n, nonce: 0x97n,
    });
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(GOLDILOCKS_PRIME - 1n);
    for (const [amount, nonce] of [
      [GOLDILOCKS_PRIME, 0x94n],
      [GOLDILOCKS_PRIME + 1n, 0x95n],
      [(1n << 64n) - 1n, 0x96n],
    ] as const) {
      const { publicInputs, slotData, nonceHex } = await prepareWithdrawal({
        bridge, stateManager, recipient: recipient.address, token: token.address, amount, nonce,
      });
      const [failedSlots, reasons] = await bridge.connect(recipient).callStatic.batchClaimWithdrawal(
        new Array(8).fill(0n), publicInputs, slotData,
      );
      expect(failedSlots.map((v) => Number(v))).to.deep.equal([0]);
      expect(reasons.map((v) => Number(v))).to.deep.equal([CLAIM_REASON.AMOUNT_OUT_OF_RANGE]);

      const tx = await bridge.batchClaimWithdrawal(new Array(8).fill(0n), publicInputs, slotData);
      const receipt = await tx.wait();
      const failed = (receipt.events ?? []).filter((e) => e.event === "WithdrawalClaimItemFailed");
      expect(failed.length).to.equal(1);
      expect(failed[0].args?.nonce).to.equal(nonceHex);
      expect(Number(failed[0].args?.slotIndex)).to.equal(0);
      expect(Number(failed[0].args?.reason)).to.equal(CLAIM_REASON.AMOUNT_OUT_OF_RANGE);

      expect(await bridge.claimedNullifiers(nonceHex)).to.equal(false);
      expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(GOLDILOCKS_PRIME - 1n);
    }
  });
});
