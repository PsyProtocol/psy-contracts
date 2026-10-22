import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
import { buildWithdrawalBatchClaimSingle } from "./helpers/withdrawalClaim";
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

describe("Bridge", function () {
  it("disables direct recordDeposit entrypoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);

    await token.mint(user.address, 1000n);
    await token.connect(user).approve(bridge.address, 250n);
    await expect(
      bridge.connect(user).recordDeposit(token.address, 250n, ethers.utils.hexZeroPad("0x7b", 32), ethers.utils.hexZeroPad("0xbb9", 32))
    ).to.be.revertedWithCustomError(bridge, "DirectDepositDisabled");
  });

  it("claims withdrawal with Groth16 proof inputs and marks nullifier", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);

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
    });

    const before = await token.balanceOf(user.address);
    await expect(
      bridge.batchClaimWithdrawal(proof, publicInputs, slotData)
    ).to.emit(bridge, "WithdrawalPendingCreated");

    expect(await token.balanceOf(user.address)).to.equal(before);

    const nullifier = ethers.utils.hexZeroPad(`0x${nonce.toString(16)}`, 32);
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
    await configureFlowToken(bridge, token.address);

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
      bridgeUserId: 1,
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "InvalidPublicInputs"
    );
  });

  it("rejects duplicate withdrawal claim with same nullifier", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);

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
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.emit(bridge, "WithdrawalPendingCreated");
    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "NullifierAlreadyClaimed"
    );
  });

  it("rejects withdrawal claim with wrong destination chain", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

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
    const { publicInputs, slotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destinationChainIndex: 1,
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "WrongDestinationChain"
    );
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
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "InvalidWithdrawalProof"
    );
  });
});
