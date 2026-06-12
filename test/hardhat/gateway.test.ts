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

function buildWithdrawalClaimPublicInputs(params: {
  withdrawalRoot: string;
  leafHash: string;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destChainId: number;
}): bigint[] {
  return [
    ...bytes32ToU32x8(params.withdrawalRoot),
    ...bytes32ToU32x8(params.leafHash),
    ...bytes32ToU32x8(addrToBytes32(params.recipient)),
    ...bytes32ToU32x8(addrToBytes32(params.token)),
    ...uint256ToU32x8(params.amount),
    params.nonce & 0xffff_ffffn,
    BigInt(params.destChainId),
    0n,
    0n,
  ];
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

    const leafHash = ethers.utils.keccak256(
      ethers.utils.solidityPack(
        ["bytes32", "bytes32", "uint256", "uint32", "uint32"],
        [addrToBytes32(user.address), addrToBytes32(token.address), amount, nonce, 0]
      )
    );

    const depositLeaf = await sm.withdrawalSubtreeRoot();
    const deposit = mkTopProof(depositLeaf, 0);
    const withdrawal = mkTopProof(ethers.utils.hexZeroPad("0x9999", 32), 0);
    const roots = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];
    await sm.finalize(DUMMY_GNARK_PROOF, deposit.root, roots, withdrawal.root, 0, 1, deposit.proof, withdrawal.proof);

    const proof = new Array(8).fill(0n);
    const publicInputs = buildWithdrawalClaimPublicInputs({
      withdrawalRoot: withdrawal.proof[0],
      leafHash,
      recipient: user.address,
      token: token.address,
      amount,
      nonce,
      destChainId: 0,
    });

    const claimCallData = bridge.interface.encodeFunctionData("claimWithdrawal", [
      proof,
      publicInputs,
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
