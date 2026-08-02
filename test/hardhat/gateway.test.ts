import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
import { DUMMY_GNARK_PROOF } from "./helpers/mockProof";
import { buildWithdrawalBatchClaimSingle } from "./helpers/withdrawalClaim";

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

describe("Multicall3 claim", function () {
  it("batches claimWithdrawal calls to bridge", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const M = await ethers.getContractFactory("Multicall3");
    const multicall = await M.deploy();
    await multicall.deployed();

    const T = await ethers.getContractFactory("MockERC20");
    const token = await T.deploy("Mock", "MOCK");
    await token.deployed();
    const amount = 99n;
    const nonce = 9n;
    await token.mint(bridge.address, amount);

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x9999", 32), 0);
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
    const claimCallData = bridge.interface.encodeFunctionData("batchClaimWithdrawal", [
      proof,
      publicInputs,
      slotData,
    ]);
    await multicall.aggregate3([
      {
        target: bridge.address,
        allowFailure: false,
        callData: claimCallData,
      },
    ]);

    expect(await token.balanceOf(user.address)).to.equal(amount);
  });
});
