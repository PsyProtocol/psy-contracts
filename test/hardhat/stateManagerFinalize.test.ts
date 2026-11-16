import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
import { DUMMY_GNARK_PROOF } from "./helpers/mockProof";

function roots(first: string, last: string): string[] {
  const arr = new Array(2).fill(ethers.constants.HashZero);
  arr[0] = first;
  arr[1] = last;
  return arr;
}

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

const EMPTY_DEPOSIT_ROOT = "0xd65af5933a094e8329332a714327ba72b1e4dac93c0cde8ee479b9bb36c3fc43";
const DEPOSIT_BATCH_SLOT_WORDS = 41;
const DEPOSIT_BATCH_SLOT_COUNT = 32;

function bytes32ToLeWords(value: string): bigint[] {
  const hex = value.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  const words: bigint[] = [];
  for (let i = 7; i >= 0; i--) words.push(BigInt(`0x${hex.slice(i * 8, i * 8 + 8)}`));
  return words;
}

function bytes32ToBeWords(value: string): bigint[] {
  const hex = value.toLowerCase().replace(/^0x/, "").padStart(64, "0");
  const words: bigint[] = [];
  for (let i = 0; i < 8; i++) words.push(BigInt(`0x${hex.slice(i * 8, i * 8 + 8)}`));
  return words;
}

function u32WordsToBytes(words: readonly bigint[]): string {
  return ethers.utils.hexConcat(words.map((word) => ethers.utils.hexZeroPad(ethers.utils.hexlify(word), 4)));
}

function concatFromLeRoot(value: string): string {
  return u32WordsToBytes(bytes32ToLeWords(value));
}

type DepositSigner = { address: string } & Parameters<Contract["connect"]>[0];

async function registerDepositSubtree(
  bridge: Contract,
  router: Contract,
  erc20Gateway: Contract,
  batchVerifier: Contract,
  depositor: DepositSigner,
  producedRoot: string,
): Promise<string> {
  const token = await (await ethers.getContractFactory("MockERC20")).deploy("Mock", "MOCK");
  await token.deployed();
  const l2TokenId = ethers.utils.hexZeroPad("0x01", 32);
  const shieldAddress = ethers.utils.hexZeroPad("0x02", 32);
  const noteCommitment = ethers.utils.hexZeroPad("0x03", 32);
  await configureFlowToken(bridge, token.address);
  await router.setTokenMapping(token.address, l2TokenId);
  await token.mint(depositor.address, 1);
  await token.connect(depositor).approve(erc20Gateway.address, 1);
  await router.connect(depositor).deposit(token.address, 1, shieldAddress, noteCommitment);
  const leaf = String(await bridge.depositLeafHashes(0));
  const slotData = new Array<bigint>(DEPOSIT_BATCH_SLOT_WORDS * DEPOSIT_BATCH_SLOT_COUNT).fill(0n);
  [shieldAddress, ethers.utils.hexZeroPad(token.address, 32), l2TokenId, ethers.utils.hexZeroPad("0x01", 32)].forEach((field, index) => {
    bytes32ToBeWords(field).forEach((word, wordIndex) => {
      slotData[index * 8 + wordIndex] = word;
    });
  });
  bytes32ToBeWords(noteCommitment).forEach((word, wordIndex) => {
    slotData[33 + wordIndex] = word;
  });
  const commit = ethers.utils.keccak256(u32WordsToBytes(slotData));
  const publicInputs = new Array<bigint>(18 + 32 * 8 + 32 * 16 + 1 + 8).fill(0n);
  bytes32ToLeWords(EMPTY_DEPOSIT_ROOT).forEach((word, i) => { publicInputs[i] = word; });
  bytes32ToLeWords(producedRoot).forEach((word, i) => { publicInputs[8 + i] = word; });
  publicInputs[17] = 1n;
  bytes32ToBeWords(leaf).forEach((word, i) => { publicInputs[18 + i] = word; });
  bytes32ToBeWords(commit).forEach((word, i) => { publicInputs[18 + 32 * 8 + 32 * 16 + 1 + i] = word; });
  await bridge.setDepositBatchVerifier(batchVerifier.address);
  await bridge.batchAppend(new Array(8).fill(0), publicInputs, slotData);
  return concatFromLeRoot(producedRoot);
}

describe("StateManager.finalize", function () {
  it("updates finalized checkpoint fields", async function () {
    const [owner, proposer] = await ethers.getSigners();
    const { stateManager: sm, bridge, router, erc20Gateway, batchVerifier } = await deployCoreSystem(owner.address, proposer.address);

    const producedRoot = ethers.utils.hexZeroPad("0x4455", 32);
    const registeredRoot = await registerDepositSubtree(bridge, router, erc20Gateway, batchVerifier, owner, producedRoot);
    const deposit = mkTopProof(registeredRoot, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0xaa", 32), 0);

    await expect(
      sm.connect(proposer).finalize(
        DUMMY_GNARK_PROOF,
        deposit.root,
        roots(ethers.utils.hexZeroPad("0x01", 32), ethers.utils.hexZeroPad("0x02", 32)),
        withdrawal.root,
        0,
        10,
        deposit.proof,
        withdrawal.proof
      )
    ).to.not.be.reverted;

    expect(await sm.lastFinalizedCheckpointId()).to.equal(10n);
    expect(await sm.checkpointTreeRootCheckpointId(ethers.utils.hexZeroPad("0x02", 32))).to.equal(10n);
    expect(await sm.lastVerifiedDepositTreeRoot()).to.equal(deposit.root);
    expect(await sm.lastVerifiedWithdrawalTreeRoot()).to.equal(withdrawal.root);
    expect(await sm.withdrawalSubtreeRoot()).to.equal(withdrawal.proof[0]);
    expect(await sm.knownDepositSubtreeRoots(registeredRoot)).to.equal(true);
    expect(await sm.knownDepositSubtreeRoots(producedRoot)).to.equal(false);
    expect(await bridge.depositRoot()).to.equal(producedRoot);
    expect(await sm.knownWithdrawalSubtreeRoots(withdrawal.proof[0])).to.equal(true);
  });
});
