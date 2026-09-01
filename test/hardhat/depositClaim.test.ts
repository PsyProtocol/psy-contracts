import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
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

function addrToBytes32(addr: string): string {
  return ethers.utils.hexZeroPad(addr, 32);
}

function u32ToBytes32(value: number): string {
  return ethers.utils.hexZeroPad(ethers.utils.hexlify(value), 32);
}

function depositLeafCompat(
  shieldAddress: string,
  token: string,
  l2TokenId: string,
  amount: bigint,
  chainIndex: number,
  noteCommitment: string
): string {
  return ethers.utils.solidityKeccak256(
    ["bytes32", "bytes32", "bytes32", "uint256", "uint32", "bytes32"],
    [
      shieldAddress,
      addrToBytes32(token),
      l2TokenId,
      amount,
      chainIndex,
      noteCommitment,
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
    await configureFlowToken(bridge, token.address);
    await configureFlowToken(bridge, ethers.constants.AddressZero, {
      smallWithdrawalMax: 2_000_000_000n,
      lifetimeWithdrawalThreshold: 4_000_000_000n,
    });

    const l2TokenId = ethers.utils.hexZeroPad("0x1234", 32);
    const l2EthTokenId = ethers.utils.hexZeroPad("0x8888", 32);
    await router.connect(owner).setTokenMapping(token.address, l2TokenId);
    await router.connect(owner).setTokenMapping(ethers.constants.AddressZero, l2EthTokenId);

    // ERC20 deposit
    await token.mint(user.address, 1000n);
    await token.connect(user).approve(erc20Gateway.address, 300n);
    const l2Recipient1 = ethers.utils.hexZeroPad("0x2a", 32);
    const noteCommitment1 = u32ToBytes32(2001);
    const tx1 = await router.connect(user).deposit(token.address, 300n, l2Recipient1, noteCommitment1);
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
      noteCommitment1
    );
    expect((depLog1 as any).args.leafHash).to.equal(expectedLeaf1);
    expect(await token.balanceOf(bridge.address)).to.equal(300n);

    // ETH deposit (wrapped to WETH9 then transferred to bridge)
    const oneEth = 1_000_000_000n;
    const l2Recipient2 = ethers.utils.hexZeroPad("0x07", 32);
    const noteCommitment2 = u32ToBytes32(2002);
    const tx2 = await router.connect(user).deposit(ethers.constants.AddressZero, oneEth, l2Recipient2, noteCommitment2, { value: oneEth });
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
      noteCommitment2
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
    await configureFlowToken(bridge, token.address);
    await configureFlowToken(bridge, ethers.constants.AddressZero, {
      smallWithdrawalMax: 2_000_000_000n,
      lifetimeWithdrawalThreshold: 4_000_000_000n,
    });

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
    const { publicInputs: erc20PublicInputs, slotData: erc20SlotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawalTop1.proof[0],
      recipient: user.address,
      token: token.address,
      amount: erc20Amount,
      nonce: erc20Nonce,
      destinationChainIndex: 0,
    });

    await expect(
      bridge.batchClaimWithdrawal(proof, erc20PublicInputs, erc20SlotData)
    ).to.not.be.reverted;
    expect(await token.balanceOf(user.address)).to.equal(0);
    await bridge.claimPendingWithdrawal(ethers.utils.hexZeroPad(`0x${erc20Nonce.toString(16)}`, 32));
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

    const { publicInputs: ethPublicInputs, slotData: ethSlotData } = buildWithdrawalBatchClaimSingle({
      withdrawalRoot: withdrawalTop2.proof[0],
      recipient: user.address,
      token: ethers.constants.AddressZero,
      amount: ethAmount,
      nonce: ethNonce,
      destinationChainIndex: 0,
    });

    await expect(
      bridge.batchClaimWithdrawal(proof, ethPublicInputs, ethSlotData)
    ).to.not.changeEtherBalance(user, ethAmount);
    await expect(
      bridge.claimPendingWithdrawal(ethers.utils.hexZeroPad(`0x${ethNonce.toString(16)}`, 32))
    ).to.changeEtherBalance(user, ethAmount);
  });
});
