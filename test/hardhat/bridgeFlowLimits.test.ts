import { expect } from "chai";
import { ethers, network } from "hardhat";
import {
  configureFlowToken,
  defaultFlowConfig,
  deployCoreSystem,
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
  await stateManager.finalize(
    DUMMY_GNARK_PROOF,
    deposit.root,
    [ethers.utils.hexZeroPad("0x01", 32), ethers.utils.hexZeroPad("0x02", 32)],
    withdrawal.root,
    0,
    1,
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
        depositCapacity: 500,
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
      depositCapacity: 500,
      depositRefillPerSecond: 1,
    });

    const oldHash = await bridge.getTokenFlowConfigHash(token);
    const before = (await bridge.getMaterializedDepositBucket(token)).available;
    const next = defaultFlowConfig({
      depositCapacity: 1_000,
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

  it("registers a delayed pending withdrawal and settles the full amount once", async function () {
    const [owner, recipient, keeper] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockERC20");
    const token = await factory.deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 100,
      mediumWithdrawalMax: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 60,
      largeWithdrawalDelay: 3_600,
    });

    // This amount enters the large tier. Amount tiers determine the wait and
    // never cap the registered amount or split settlement.
    const amount = 700n;
    await token.mint(bridge.address, amount);
    const before = await token.balanceOf(recipient.address);
    const nonce = await registerWithdrawal({
      bridge,
      stateManager,
      recipient: recipient.address,
      token: token.address,
      amount,
      nonce: 9001n,
    });

    const pending = await bridge.pendingWithdrawals(nonce);
    expect(pending.amount).to.equal(amount);
    expect(await token.balanceOf(recipient.address)).to.equal(before);
    expect(await bridge.claimedNullifiers(nonce)).to.equal(true);
    await expect(bridge.connect(keeper).claimPendingWithdrawal(nonce)).to.be.revertedWithCustomError(
      bridge,
      "PendingWithdrawalNotClaimable",
    );

    const oldHash = await bridge.getTokenFlowConfigHash(token.address);
    await bridge.setTokenFlowConfig(token.address, defaultFlowConfig({
      smallWithdrawalMax: 100,
      mediumWithdrawalMax: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 60,
      largeWithdrawalDelay: 7_200,
    }), oldHash);
    expect((await bridge.pendingWithdrawals(nonce)).claimableAt).to.equal(pending.claimableAt);

    await network.provider.send("evm_setNextBlockTimestamp", [pending.claimableAt.toNumber()]);
    await bridge.connect(keeper).claimPendingWithdrawal(nonce);
    expect(await token.balanceOf(recipient.address)).to.equal(before.add(amount));
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(0);
    await expect(bridge.connect(keeper).claimPendingWithdrawal(nonce)).to.be.revertedWithCustomError(
      bridge,
      "PendingWithdrawalNotFound",
    );
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
});
