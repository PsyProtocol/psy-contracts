import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
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

function addrToBytes32(addr: string): string {
  return ethers.utils.hexZeroPad(addr, 32);
}

function bytes32ToU32x8(value: string): bigint[] {
  const bytes = ethers.utils.arrayify(ethers.utils.hexZeroPad(value, 32));
  const words: bigint[] = [];
  for (let i = 0; i < 8; i++) {
    const offset = i * 4;
    const word =
      (BigInt(bytes[offset]) << 24n) |
      (BigInt(bytes[offset + 1]) << 16n) |
      (BigInt(bytes[offset + 2]) << 8n) |
      BigInt(bytes[offset + 3]);
    words.push(word);
  }
  return words;
}

function uint256ToU32x8(value: bigint): bigint[] {
  const hex = ethers.utils.hexZeroPad(`0x${value.toString(16)}`, 32);
  return bytes32ToU32x8(hex);
}

function batchSlotDataCommit(slotData: bigint[]): string {
  const bytes: number[] = [];
  for (const word of slotData) {
    const normalized = Number(word & 0xffff_ffffn);
    bytes.push((normalized >>> 24) & 0xff, (normalized >>> 16) & 0xff, (normalized >>> 8) & 0xff, normalized & 0xff);
  }
  return ethers.utils.keccak256(Uint8Array.from(bytes));
}

function buildWithdrawalBatchClaimPublicInputsSingle(params: {
  withdrawalRoot: string;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destChainId: number;
  leafIndex?: number;
  bridgeUserId?: number;
}): { publicInputs: bigint[]; slotData: bigint[] } {
  const out = new Array<bigint>(18).fill(0n);
  const slotData = new Array<bigint>(832).fill(0n);
  const pushAt = (offset: number, words: bigint[]) => {
    for (let i = 0; i < words.length; i++) out[offset + i] = words[i];
  };
  const pushSlotAt = (offset: number, words: bigint[]) => {
    for (let i = 0; i < words.length; i++) slotData[offset + i] = words[i];
  };
  pushAt(0, bytes32ToU32x8(params.withdrawalRoot));
  out[8] = 1n;
  out[9] = BigInt(params.bridgeUserId ?? 524288);
  pushSlotAt(0, bytes32ToU32x8(addrToBytes32(params.recipient)));
  pushSlotAt(8, bytes32ToU32x8(addrToBytes32(params.token)));
  pushSlotAt(16, uint256ToU32x8(params.amount));
  slotData[24] = params.nonce & 0xffff_ffffn;
  slotData[25] = BigInt(params.destChainId);
  pushAt(10, bytes32ToU32x8(batchSlotDataCommit(slotData)));
  return { publicInputs: out, slotData };
}

describe("Bridge", function () {
  it("disables direct recordDeposit entrypoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

    await token.mint(user.address, 1000n);
    await token.connect(user).approve(bridge.address, 250n);
    await expect(
      bridge.connect(user).recordDeposit(token.address, 250n, ethers.utils.hexZeroPad("0x7b", 32), 3001)
    ).to.be.revertedWithCustomError(bridge, "DirectDepositDisabled");
  });

  it("claims withdrawal with Groth16 proof inputs and marks nullifier", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

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
    const { publicInputs, slotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destChainId: 0,
    });

    const before = await token.balanceOf(user.address);
    await expect(
      bridge.batchClaimWithdrawal(proof, publicInputs, slotData)
    ).to.emit(bridge, "WithdrawalClaimed");

    expect(await token.balanceOf(user.address)).to.equal(before + amount);

    const leafHash = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["bytes32", "bytes32", "uint256", "uint32", "uint32"],
        [addrToBytes32(user.address), addrToBytes32(token.address), amount, nonce, 0]
      )
    );
    expect(await bridge.claimedNullifiers(leafHash)).to.equal(true);
  });

  it("rejects withdrawal claim with wrong bridge user id in public inputs", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

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
    const { publicInputs, slotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destChainId: 0,
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
    const { publicInputs, slotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destChainId: 0,
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.emit(bridge, "WithdrawalClaimed");
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
    const { publicInputs, slotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: withdrawal.proof[0],
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destChainId: 1,
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
    const { publicInputs, slotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: ethers.utils.hexZeroPad("0xdead", 32),
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destChainId: 0,
    });

    await expect(bridge.batchClaimWithdrawal(proof, publicInputs, slotData)).to.be.revertedWithCustomError(
      bridge,
      "InvalidWithdrawalProof"
    );
  });
});
