import { expect } from "chai";
import { ethers, network } from "hardhat";
import { configureFlowToken, deployCoreSystem, tokenSetHash } from "./helpers/deploySystem";
import { buildWithdrawalBatchClaim, buildWithdrawalBatchClaimSingle, patchBatchCommit, withdrawalIdOf } from "./helpers/withdrawalClaim";
import { DUMMY_GNARK_PROOF } from "./helpers/mockProof";

function mkTopProof(leaf: string, index: number): { proof: string[]; root: string } {
  const proof = new Array(9).fill(ethers.constants.HashZero);
  proof[0] = leaf;
  let cur = leaf;
  for (let i = 0; i < 8; i++) {
    const sib = ethers.utils.keccak256(ethers.utils.solidityPack(["string", "uint8"], ["sib", i]));
    proof[i + 1] = sib;
    const bit = (index >> i) & 1;
    cur = bit === 0
      ? ethers.utils.keccak256(ethers.utils.solidityPack(["bytes32", "bytes32"], [cur, sib]))
      : ethers.utils.keccak256(ethers.utils.solidityPack(["bytes32", "bytes32"], [sib, cur]));
  }
  return { proof, root: cur };
}

const GOLDILOCKS_PRIME = 18446744069414584321n;
const REASON = {
  ADDRESS_HIGH_BITS: 1,
  WRONG_DESTINATION_CHAIN: 2,
  ZERO_ADDRESS: 3,
  ZERO_AMOUNT: 4,
  NULLIFIER_ALREADY_CLAIMED: 5,
  TOKEN_NOT_CONFIGURED: 6,
  REGISTRATION_PAUSED: 7,
  AMOUNT_OUT_OF_RANGE: 8,
  TOTAL_AMOUNT_OVERFLOW: 9,
  CLAIMABLE_AT_OVERFLOW: 10,
} as const;


async function setupBatchClaimFixture(amount: bigint) {
  const [owner, user] = await ethers.getSigners();
  const { bridge, stateManager: sm, router } = await deployCoreSystem(owner.address, owner.address);
  const TokenFactory = await ethers.getContractFactory("MockERC20");
  const token = await TokenFactory.deploy("Mock", "MOCK");
  await token.deployed();
  await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });
  await router.connect(owner).setTokenMapping(token.address, ethers.utils.hexZeroPad("0x01", 32));
  await token.mint(bridge.address, amount);
  const depositLeaf = await sm.withdrawalSubtreeRoot();
  const deposit = mkTopProof(depositLeaf, 0);
  const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x1234", 32), 0);
  const roots = [
    ethers.utils.hexZeroPad("0x01", 32),
    ethers.utils.hexZeroPad("0x02", 32),
  ];
  await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);
  return { owner, user, bridge, sm, router, token, withdrawalRoot: withdrawal.proof[0] };
}

describe("Bridge", function () {
  it("disables direct recordDeposit entrypoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });

    await token.mint(user.address, 1000n);
    await token.connect(user).approve(bridge.address, 250n);
    await expect(
      bridge.connect(user).recordDeposit(token.address, 250n, ethers.utils.hexZeroPad("0x7b", 32), ethers.utils.hexZeroPad("0xbb9", 32))
    ).to.be.revertedWithCustomError(bridge, "DirectDepositDisabled");
  });

  it("claims withdrawal with Groth16 proof inputs and marks nullifier", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm, router } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });
    await router.connect(owner).setTokenMapping(token.address, ethers.utils.hexZeroPad("0x01", 32));

    const amount = 777n;
    const nonce = 42n;
    await token.mint(bridge.address, amount);

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x1234", 32), 0);
    const roots = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];

    await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);

    const proof = new Array(8).fill(0n);
    const { publicInputs, slotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destinationChainIndex: 0,
      tokenContractId: 1,
    });

    const before = await token.balanceOf(user.address);
    await expect(
      bridge.batchClaimWithdrawal(proof, publicInputs, slotData)
    ).to.emit(bridge, "WithdrawalPendingCreated");

    expect(await token.balanceOf(user.address)).to.equal(before);

    const nullifier = withdrawalIdOf({ recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 });
    expect(await bridge.claimedNullifiers(nullifier)).to.equal(true);
    expect((await bridge.pendingWithdrawals(nullifier)).amount).to.equal(amount);
    await bridge.claimPendingWithdrawal(nullifier);
    expect(await token.balanceOf(user.address)).to.equal(before + amount);
  });

  it("rejects withdrawal claim with wrong bridge user id in public inputs", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });

    const amount = 777n;
    const nonce = 42n;
    await token.mint(bridge.address, amount);

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x1234", 32), 0);
    const roots = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];

    await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);

    const proof = new Array(8).fill(0n);
    const { publicInputs, slotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destinationChainIndex: 0,
      tokenContractId: 0,
      bridgeUserId: 1,
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "InvalidPublicInputs"
    );
  });

  it("skips an already claimed nullifier with reason 5 and keeps prior state", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm, router } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });
    await router.connect(owner).setTokenMapping(token.address, ethers.utils.hexZeroPad("0x01", 32));

    const amount = 333n;
    const nonce = 77n;
    await token.mint(bridge.address, amount);

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x1234", 32), 0);
    const roots = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];

    await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);

    const proof = new Array(8).fill(0n);
    const { publicInputs, slotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destinationChainIndex: 0,
      tokenContractId: 1,
    });
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.emit(bridge, "WithdrawalPendingCreated");
    const totalsBefore = await bridge.totalWithdrawalAmount(token.address);

    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([0]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([REASON.NULLIFIER_ALREADY_CLAIMED]);

    const tx = await bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData);
    const receipt = await tx.wait();
    const failedEvents = (receipt.events ?? []).filter((e) => e.event === "WithdrawalClaimItemFailed");
    expect(failedEvents.length).to.equal(1);
    expect(failedEvents[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(nonce));
    expect(Number(failedEvents[0].args?.slotIndex)).to.equal(0);
    expect(Number(failedEvents[0].args?.reason)).to.equal(REASON.NULLIFIER_ALREADY_CLAIMED);
    const createdEvents = (receipt.events ?? []).filter((e) => e.event === "WithdrawalPendingCreated");
    expect(createdEvents.length).to.equal(0, "the claimed nonce must not re-register");

    const nullifier = withdrawalIdForNonce(nonce);
    expect(await bridge.claimedNullifiers(nullifier)).to.equal(true);
    expect((await bridge.pendingWithdrawals(nullifier)).amount).to.equal(amount);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(totalsBefore);
  });

  it("skips a wrong destination chain slot with reason 2", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });

    const amount = 444n;
    const nonce = 78n;
    await token.mint(bridge.address, amount);

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x1234", 32), 0);
    const roots = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];

    await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);

    const proof = new Array(8).fill(0n);
    const destinationChainIndex = Number(await sm.l1ChainIndex()) + 1;
    const { publicInputs, slotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destinationChainIndex,
      tokenContractId: 0,
    });
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: token.address, amount, nonce, destinationChainIndex, tokenContractId: 0 });

    const [failedSlots, reasons] = await bridge.callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([0]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([REASON.WRONG_DESTINATION_CHAIN]);

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData))
      .to.emit(bridge, "WithdrawalClaimItemFailed")
      .withArgs(withdrawalIdForNonce(nonce), 0, REASON.WRONG_DESTINATION_CHAIN);
    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(nonce))).to.equal(false);
    expect((await bridge.pendingWithdrawals(withdrawalIdForNonce(nonce))).amount).to.equal(0);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(0);
  });

  it("rejects withdrawal claim with wrong withdrawal root in public inputs", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

    const amount = 555n;
    const nonce = 79n;
    await token.mint(bridge.address, amount);

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x1234", 32), 0);
    const roots = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];

    await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);

    const proof = new Array(8).fill(0n);
    const { publicInputs, slotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: ethers.utils.hexZeroPad("0xdead", 32),
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destinationChainIndex: 0,
      tokenContractId: 0,
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "InvalidWithdrawalProof"
    );
  });
  function commitHexOf(publicInputs: bigint[]): string {
    let hex = "0x";
    for (let index = 10; index < 18; index++) {
      hex += publicInputs[index].toString(16).padStart(8, "0");
    }
    return hex;
  }

  it("skips prior claimed nonce and registers the valid slot", async function () {
    const { user, bridge, token, withdrawalRoot } = await setupBatchClaimFixture(1000n);
    const amount = 300n;
    const claimedNonce = 11n;
    const freshNonce = 12n;
    const proof = new Array(8).fill(0n);
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 });

    const first = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [{ recipient: user.address, token: token.address, amount, nonce: claimedNonce, destinationChainIndex: 0, tokenContractId: 1 }],
    });
    await bridge.batchClaimWithdrawal(proof, first.publicInputs, first.slotData);
    const claimedPending = await bridge.pendingWithdrawals(withdrawalIdForNonce(claimedNonce));
    const totalsBefore = await bridge.totalWithdrawalAmount(token.address);

    const second = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [
        { recipient: user.address, token: token.address, amount, nonce: claimedNonce, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount, nonce: freshNonce, destinationChainIndex: 0, tokenContractId: 1 },
      ],
    });
    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, second.publicInputs, second.slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([0]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([REASON.NULLIFIER_ALREADY_CLAIMED]);

    const tx = await bridge.connect(user).batchClaimWithdrawal(proof, second.publicInputs, second.slotData);
    const receipt = await tx.wait();
    const events = receipt.events ?? [];
    const failed = events.filter((e) => e.event === "WithdrawalClaimItemFailed");
    expect(failed.length).to.equal(1);
    expect(failed[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(claimedNonce));
    expect(Number(failed[0].args?.slotIndex)).to.equal(0);
    const created = events.filter((e) => e.event === "WithdrawalPendingCreated");
    expect(created.length).to.equal(1);
    expect(created[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(freshNonce));

    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(claimedNonce))).to.equal(true);
    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(freshNonce))).to.equal(true);
    const claimedAfter = await bridge.pendingWithdrawals(withdrawalIdForNonce(claimedNonce));
    expect(claimedAfter.amount).to.equal(claimedPending.amount);
    expect(claimedAfter.claimableAt).to.equal(claimedPending.claimableAt);
    expect(Number(await bridge.totalWithdrawalAmount(token.address))).to.equal(Number(totalsBefore) + Number(amount));
  });

  it("registers first duplicate nonce once and fails later duplicates with reason 5", async function () {
    const { user, bridge, token, withdrawalRoot } = await setupBatchClaimFixture(1000n);
    const amount = 200n;
    const nonce = 21n;
    const otherNonce = 22n;
    const proof = new Array(8).fill(0n);
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 });

    const { publicInputs, slotData } = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [
        { recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount, nonce: otherNonce, destinationChainIndex: 0, tokenContractId: 1 },
      ],
    });

    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([1]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([REASON.NULLIFIER_ALREADY_CLAIMED]);

    const tx = await bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData);
    const receipt = await tx.wait();
    const events = receipt.events ?? [];
    const created = events.filter((e) => e.event === "WithdrawalPendingCreated");
    expect(created.length).to.equal(2, "one per distinct nonce");
    expect(created.map((e) => e.args?.withdrawalId)).to.deep.equal([withdrawalIdForNonce(nonce), withdrawalIdForNonce(otherNonce)]);
    const failed = events.filter((e) => e.event === "WithdrawalClaimItemFailed");
    expect(failed.length).to.equal(1);
    expect(failed[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(nonce), "same nonce may appear in both event kinds");
    expect(Number(failed[0].args?.slotIndex)).to.equal(1, "slot index disambiguates the duplicate");

    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(nonce))).to.equal(true);
    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(otherNonce))).to.equal(true);
    expect(Number(await bridge.totalWithdrawalAmount(token.address))).to.equal(Number(amount) * 2);
  });

  it("succeeds with every slot failing and leaves no state change", async function () {
    const [owner] = await ethers.getSigners();
    const { user, bridge, sm, router, token, withdrawalRoot } = await setupBatchClaimFixture(1000n);
    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const unconfigured = await TokenFactory.deploy("Unconfigured", "UNCF");
    await unconfigured.deployed();
    await router.connect(owner).setTokenMapping(unconfigured.address, ethers.utils.hexZeroPad("0x02", 32));
    const amount = 100n;
    const chainIndex = Number(await sm.l1ChainIndex());
    const proof = new Array(8).fill(0n);

    const items = [
      { recipient: ethers.constants.AddressZero, token: token.address, amount, nonce: 31n, destinationChainIndex: 0, tokenContractId: 1 },
      { recipient: user.address, token: token.address, amount: 0n, nonce: 32n, destinationChainIndex: 0, tokenContractId: 1 },
      { recipient: user.address, token: token.address, amount, nonce: 33n, destinationChainIndex: chainIndex + 1, tokenContractId: 1 },
      { recipient: user.address, token: unconfigured.address, amount, nonce: 34n, destinationChainIndex: 0, tokenContractId: 2 },
      { recipient: ethers.utils.hexZeroPad(user.address, 32).replace(/^0x00000000/, "0x00000001"), token: token.address, amount, nonce: 35n, destinationChainIndex: 0, tokenContractId: 1 },
    ];
    const { publicInputs, slotData } = buildWithdrawalBatchClaim({ withdrawalRoot, items });
    patchBatchCommit(publicInputs, slotData);

    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([0, 1, 2, 3, 4]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([
      REASON.ZERO_ADDRESS,
      REASON.ZERO_AMOUNT,
      REASON.WRONG_DESTINATION_CHAIN,
      REASON.TOKEN_NOT_CONFIGURED,
      REASON.ADDRESS_HIGH_BITS,
    ]);

    const tx = await bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData);
    const receipt = await tx.wait();
    const summary = (receipt.events ?? []).find((e) => e.event === "WithdrawalClaimBatchResult");
    expect(Number(summary?.args?.realCount)).to.equal(5);
    expect(Number(summary?.args?.succeededCount)).to.equal(0);
    expect(Number(summary?.args?.failedCount)).to.equal(5);

    for (const item of items) {
      expect(await bridge.claimedNullifiers(withdrawalIdOf(item))).to.equal(false);
    }
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(0);
    expect(await bridge.totalWithdrawalAmount(unconfigured.address)).to.equal(0);
    expect((await bridge.pendingWithdrawals(withdrawalIdOf(items[0]))).amount).to.equal(0);
  });

  it("skips paused token slot with reason 7 and settles other token", async function () {
    const [owner] = await ethers.getSigners();
    const { user, bridge, router, token, withdrawalRoot } = await setupBatchClaimFixture(1000n);
    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const tokenB = await TokenFactory.deploy("Mock B", "MOCKB");
    await tokenB.deployed();
    await configureFlowToken(bridge, tokenB.address, { smallWithdrawalMax: 0, mediumWithdrawalDelay: 0 });
    await router.connect(owner).setTokenMapping(tokenB.address, ethers.utils.hexZeroPad("0x02", 32));
    await tokenB.mint(bridge.address, 1000n);
    const amount = 150n;
    const proof = new Array(8).fill(0n);
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: nonce === 42n ? tokenB.address : token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: nonce === 42n ? 2 : 1 });

    await bridge.setTokenPauseFlags(token.address, 2);

    const { publicInputs, slotData } = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [
        { recipient: user.address, token: token.address, amount, nonce: 41n, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: tokenB.address, amount, nonce: 42n, destinationChainIndex: 0, tokenContractId: 2 },
      ],
    });

    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([0]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([REASON.REGISTRATION_PAUSED]);

    const pausedTx = await bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData);
    const pausedReceipt = await pausedTx.wait();
    const pausedEvents = pausedReceipt.events ?? [];
    const pausedFailed = pausedEvents.filter((e) => e.event === "WithdrawalClaimItemFailed");
    expect(pausedFailed.length).to.equal(1);
    expect(pausedFailed[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(41n));
    expect(Number(pausedFailed[0].args?.slotIndex)).to.equal(0);
    expect(Number(pausedFailed[0].args?.reason)).to.equal(REASON.REGISTRATION_PAUSED);
    const created = pausedEvents.filter((e) => e.event === "WithdrawalPendingCreated");
    expect(created.length).to.equal(1);
    expect(created[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(42n));

    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(41n))).to.equal(false);
    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(42n))).to.equal(true);
    expect((await bridge.pendingWithdrawals(withdrawalIdForNonce(42n))).token).to.equal(tokenB.address);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(0);
    expect(await bridge.totalWithdrawalAmount(tokenB.address)).to.equal(amount);
  });

  it("reverts whole batch on slot data commit mismatch with zero effects", async function () {
    const { user, bridge, token, withdrawalRoot } = await setupBatchClaimFixture(1000n);
    const amount = 100n;
    const proof = new Array(8).fill(0n);
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ senderUserId: 1, recipient: user.address, token: token.address, amount, nonce, destinationChainIndex: 0, tokenContractId: 1 });

    const { publicInputs, slotData } = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [{ recipient: user.address, token: token.address, amount, nonce: 51n, destinationChainIndex: 0, tokenContractId: 1 }],
    });
    slotData[0] = slotData[0] + 1n;

    await expect(bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "InvalidWithdrawalProof"
    );
    expect(await bridge.claimedNullifiers(withdrawalIdForNonce(51n))).to.equal(false);
    expect((await bridge.pendingWithdrawals(withdrawalIdForNonce(51n))).amount).to.equal(0);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(0);
  });

  it("returns failed slot indexes and reasons and logs map to input positions", async function () {
    const { user, bridge, sm, token, withdrawalRoot } = await setupBatchClaimFixture(1000n);
    const amount = 120n;
    const chainIndex = Number(await sm.l1ChainIndex());
    const proof = new Array(8).fill(0n);
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: token.address, amount: nonce === 62n ? 0n : amount, nonce, destinationChainIndex: nonce === 64n ? chainIndex + 1 : 0, tokenContractId: 1 });

    const { publicInputs, slotData } = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [
        { recipient: user.address, token: token.address, amount, nonce: 61n, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount: 0n, nonce: 62n, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount, nonce: 63n, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount, nonce: 64n, destinationChainIndex: chainIndex + 1, tokenContractId: 1 },
      ],
    });

    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([1, 3]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([REASON.ZERO_AMOUNT, REASON.WRONG_DESTINATION_CHAIN]);

    const tx = await bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData);
    const receipt = await tx.wait();
    const named = (receipt.events ?? []).filter((e) =>
      ["WithdrawalPendingCreated", "WithdrawalClaimItemFailed", "WithdrawalClaimBatchResult"].includes(e.event as string)
    );
    expect(named.map((e) => e.event)).to.deep.equal([
      "WithdrawalPendingCreated",
      "WithdrawalClaimItemFailed",
      "WithdrawalPendingCreated",
      "WithdrawalClaimItemFailed",
      "WithdrawalClaimBatchResult",
    ]);
    expect(named[0].args?.withdrawalId).to.equal(withdrawalIdForNonce(61n));
    expect(named[1].args?.withdrawalId).to.equal(withdrawalIdForNonce(62n));
    expect(Number(named[1].args?.slotIndex)).to.equal(1);
    expect(Number(named[1].args?.reason)).to.equal(REASON.ZERO_AMOUNT);
    expect(named[2].args?.withdrawalId).to.equal(withdrawalIdForNonce(63n));
    expect(named[3].args?.withdrawalId).to.equal(withdrawalIdForNonce(64n));
    expect(Number(named[3].args?.slotIndex)).to.equal(3);
    expect(Number(named[3].args?.reason)).to.equal(REASON.WRONG_DESTINATION_CHAIN);
    expect(named[4].args?.batchCommit).to.equal(commitHexOf(publicInputs));
    expect(Number(named[4].args?.realCount)).to.equal(4);
    expect(Number(named[4].args?.succeededCount)).to.equal(2);
    expect(Number(named[4].args?.failedCount)).to.equal(2);
  });

  it("registers and pays amounts at and above the Goldilocks bound", async function () {
    const { owner, user, bridge, token, withdrawalRoot } = await setupBatchClaimFixture(GOLDILOCKS_PRIME * 2n + (1n << 100n));
    const proof = new Array(8).fill(0n);
    const amounts = [GOLDILOCKS_PRIME - 1n, GOLDILOCKS_PRIME, 1n << 100n];
    const withdrawalIdForNonce = (nonce: bigint) => withdrawalIdOf({ recipient: user.address, token: token.address, amount: amounts[Number(nonce - 71n)], nonce, destinationChainIndex: 0, tokenContractId: 1 });
    const timelock = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(owner.address, 1, 100, 1, 100);
    await timelock.deployed();
    await bridge.initializeWithdrawalTotals(
      [token.address], [await bridge.getTokenFlowConfig(token.address)], [0], tokenSetHash([token.address]), timelock.address,
    );

    const { publicInputs, slotData } = buildWithdrawalBatchClaim({
      withdrawalRoot,
      items: [
        { recipient: user.address, token: token.address, amount: amounts[0], nonce: 71n, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount: amounts[1], nonce: 72n, destinationChainIndex: 0, tokenContractId: 1 },
        { recipient: user.address, token: token.address, amount: amounts[2], nonce: 73n, destinationChainIndex: 0, tokenContractId: 1 },
      ],
    });

    const [failedSlots, reasons] = await bridge.connect(user).callStatic.batchClaimWithdrawal(proof, publicInputs, slotData);
    expect(failedSlots.map((v) => Number(v))).to.deep.equal([]);
    expect(reasons.map((v) => Number(v))).to.deep.equal([]);

    const amountTx = await bridge.connect(user).batchClaimWithdrawal(proof, publicInputs, slotData);
    const amountReceipt = await amountTx.wait();
    const amountEvents = amountReceipt.events ?? [];
    expect(amountEvents.filter((e) => e.event === "WithdrawalClaimItemFailed").length).to.equal(0);
    const amountCreated = amountEvents.filter((e) => e.event === "WithdrawalPendingCreated");
    expect(amountCreated.length).to.equal(3);

    // Funded custody pays every full-uint256 withdrawal through governance
    // after its stored classification delay elapses.
    let paid = 0n;
    let maxClaimableAt = 0n;
    for (const [index, amount] of amounts.entries()) {
      const nonce = 71n + BigInt(index);
      expect(await bridge.claimedNullifiers(withdrawalIdForNonce(nonce))).to.equal(true);
      const [, pendingRecipient, pendingAmount, claimableAt] = await bridge.pendingWithdrawals(withdrawalIdForNonce(nonce));
      expect(pendingRecipient).to.equal(user.address);
      expect(pendingAmount).to.equal(amount);
      if (claimableAt > maxClaimableAt) maxClaimableAt = claimableAt;
    }
    for (const [index, amount] of amounts.entries()) {
      const nonce = 71n + BigInt(index);
      const data = bridge.interface.encodeFunctionData("forceClaimWithdrawal", [withdrawalIdForNonce(nonce)]);
      const executionTime = Math.max(Number(maxClaimableAt), (await ethers.provider.getBlock("latest")).timestamp + 2);
      await timelock.queueTransaction(bridge.address, 0, "", data, executionTime);
      await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
      await timelock.executeTransaction(bridge.address, 0, "", data, executionTime);
      paid += amount;
      expect(await token.balanceOf(user.address)).to.equal(paid);
    }
  });
});
