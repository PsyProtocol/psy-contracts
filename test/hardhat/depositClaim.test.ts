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

function u32ToBytes32(value: number): string {
  return ethers.utils.hexZeroPad(ethers.utils.hexlify(value), 32);
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

function depositLeafCompat(
  shieldAddress: string,
  token: string,
  l2TokenId: string,
  amount: bigint,
  chainIndex: number,
  noteSecretHash: string
): string {
  return ethers.utils.solidityKeccak256(
    ["bytes32", "bytes32", "bytes32", "uint256", "uint32", "bytes32"],
    [
      shieldAddress,
      addrToBytes32(token),
      l2TokenId,
      amount,
      chainIndex,
      noteSecretHash,
    ]
  );
}

describe("Deposit And Claim", function () {
  it("tests ERC20 deposit and ETH deposit separately", async function () {
    const [owner, user] = await ethers.getSigners();
    const { router, bridge, weth, erc20Gateway } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

    const l2TokenId = ethers.utils.hexZeroPad("0x1234", 32);
    const l2EthTokenId = ethers.utils.hexZeroPad("0x8888", 32);
    await router.connect(owner).setTokenMapping(token.address, l2TokenId);
    await router.connect(owner).setTokenMapping(ethers.constants.AddressZero, l2EthTokenId);

    // ERC20 deposit
    await token.mint(user.address, 1000n);
    await token.connect(user).approve(erc20Gateway.address, 300n);
    const l2Recipient1 = ethers.utils.hexZeroPad("0x2a", 32);
    const noteSecretHash1 = u32ToBytes32(2001);
    const tx1 = await router.connect(user).deposit(token.address, 300n, l2Recipient1, noteSecretHash1);
    const rc1 = await tx1.wait();
    const bridgeIface = (await ethers.getContractFactory("Bridge")).interface;
    const depLog1 = rc1!.logs
      .map((l) => {
        try {
          return bridgeIface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((x) => x && x.name === "DepositRecorded");
    expect(depLog1).to.not.equal(undefined);
    const expectedLeaf1 = depositLeafCompat(
      l2Recipient1,
      token.address,
      l2TokenId,
      300n,
      0,
      noteSecretHash1
    );
    expect((depLog1 as any).args.leafHash).to.equal(expectedLeaf1);
    expect(await token.balanceOf(bridge.address)).to.equal(300n);

    // ETH deposit (wrapped to WETH9 then transferred to bridge)
    const oneEth = 1_000_000_000n;
    const l2Recipient2 = ethers.utils.hexZeroPad("0x07", 32);
    const noteSecretHash2 = u32ToBytes32(2002);
    const tx2 = await router.connect(user).deposit(ethers.constants.AddressZero, oneEth, l2Recipient2, noteSecretHash2, { value: oneEth });
    const rc2 = await tx2.wait();
    const depLog2 = rc2!.logs
      .map((l) => {
        try {
          return bridgeIface.parseLog(l);
        } catch {
          return null;
        }
      })
      .find((x) => x && x.name === "DepositRecorded");
    expect(depLog2).to.not.equal(undefined);
    const expectedLeaf2 = depositLeafCompat(
      l2Recipient2,
      ethers.constants.AddressZero,
      l2EthTokenId,
      oneEth,
      0,
      noteSecretHash2
    );
    expect((depLog2 as any).args.leafHash).to.equal(expectedLeaf2);
    const wethAtBridge = await ethers.getContractAt("WETH9", weth.address);
    expect(await wethAtBridge.balanceOf(bridge.address)).to.equal(oneEth);
  });

  it("tests ERC20 claim and ETH claim separately", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm, weth } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();

    const erc20Amount = 777n;
    const erc20Nonce = 42n;
    await token.mint(bridge.address, erc20Amount);

    const depositLeaf1 = ethers.constants.HashZero;
    const depositTop1 = mkTopProof(depositLeaf1, 0);
    const withdrawalTop1 = mkTopProof(ethers.utils.hexZeroPad("0x1111", 32), 0);
    const roots1 = [
      ethers.utils.hexZeroPad("0x01", 32),
      ethers.utils.hexZeroPad("0x02", 32),
    ];
    await sm.finalize(DUMMY_GNARK_PROOF, depositTop1.root, roots1, withdrawalTop1.root, 0, 1, depositTop1.proof, withdrawalTop1.proof);

    const proof = new Array(8).fill(0n);
    const { publicInputs: erc20PublicInputs, slotData: erc20SlotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: withdrawalTop1.proof[0],
      recipient: user.address,
      token: token.address,
      amount: erc20Amount,
      nonce: erc20Nonce,
      destChainId: 0,
    });

    await expect(
      bridge.batchClaimWithdrawal(proof, erc20PublicInputs, erc20SlotData)
    ).to.not.be.reverted;
    expect(await token.balanceOf(user.address)).to.equal(erc20Amount);

    // ETH claim
    const ethAmount = 900_000_000n;
    const ethNonce = 43n;
    await weth.deposit({ value: ethAmount });
    await weth.transfer(bridge.address, ethAmount);

    const depositLeaf2 = ethers.constants.HashZero;
    const depositTop2 = mkTopProof(depositLeaf2, 0);
    const withdrawalTop2 = mkTopProof(ethers.utils.hexZeroPad("0x2222", 32), 0);
    const roots2 = [
      roots1[1],
      ethers.utils.hexZeroPad("0x04", 32),
    ];
    await sm.finalize(DUMMY_GNARK_PROOF, depositTop2.root, roots2, withdrawalTop2.root, 0, 2, depositTop2.proof, withdrawalTop2.proof);

    const { publicInputs: ethPublicInputs, slotData: ethSlotData } = buildWithdrawalBatchClaimPublicInputsSingle({
      withdrawalRoot: withdrawalTop2.proof[0],
      recipient: user.address,
      token: ethers.constants.AddressZero,
      amount: ethAmount,
      nonce: ethNonce,
      destChainId: 0,
    });

    await expect(
      bridge.batchClaimWithdrawal(proof, ethPublicInputs, ethSlotData)
    ).to.changeEtherBalance(user, ethAmount);
  });
});
