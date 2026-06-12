import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
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

describe("StateManager.finalize", function () {
  it("updates finalized checkpoint fields", async function () {
    const [owner, proposer] = await ethers.getSigners();
    const { stateManager: sm } = await deployCoreSystem(owner.address, proposer.address);

    const depositLeaf = ethers.constants.HashZero;
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0xaa", 32), 0);

    await expect(
      sm.connect(proposer).finalize(
        DUMMY_GNARK_PROOF,
        deposit.root,
        roots(ethers.utils.hexZeroPad("0x01", 32), ethers.utils.hexZeroPad("0x02", 32)),
        withdrawal.root,
        5,
        10,
        deposit.proof,
        withdrawal.proof
      )
    ).to.not.be.reverted;

    expect(await sm.lastFinalizedCheckpointId()).to.equal(10n);
    expect(await sm.nextConsumedDepositIndex()).to.equal(5n);
    expect(await sm.lastVerifiedDepositTreeRoot()).to.equal(deposit.root);
    expect(await sm.lastVerifiedWithdrawalTreeRoot()).to.equal(withdrawal.root);
    expect(await sm.withdrawalSubtreeRoot()).to.equal(withdrawal.proof[0]);
    expect(await sm.knownDepositSubtreeRoots(deposit.proof[0])).to.equal(true);
    expect(await sm.knownWithdrawalSubtreeRoots(withdrawal.proof[0])).to.equal(true);
  });
});
