import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";

function u32ToBytes32(value: number): string {
  return ethers.utils.hexZeroPad(ethers.utils.hexlify(value), 32);
}

describe("Router + Gateways", function () {
  it("routes ERC20 and ETH deposits through gateways", async function () {
    const [owner, user] = await ethers.getSigners();
    const { router, bridge, erc20Gateway: erc20g, weth } = await deployCoreSystem(owner.address, owner.address);

    const TokenFactory = await ethers.getContractFactory("MockERC20");
    const token = await TokenFactory.deploy("Mock", "MOCK");
    await token.deployed();
    const l2TokenId = ethers.utils.hexZeroPad("0x1234", 32);
    const l2EthTokenId = ethers.utils.hexZeroPad("0x8888", 32);
    await router.connect(owner).setTokenMapping(token.address, l2TokenId);
    await router.connect(owner).setTokenMapping(ethers.constants.AddressZero, l2EthTokenId);
    await configureFlowToken(bridge, token.address);
    await configureFlowToken(bridge, ethers.constants.AddressZero);

    await token.mint(user.address, 1000n);
    await token.connect(user).approve(erc20g.address, 300n);
    await expect(
      router.connect(user).deposit(
        token.address,
        300n,
        ethers.utils.hexZeroPad("0x2a", 32),
        u32ToBytes32(1001)
      )
    ).to.emit(bridge, "DepositRecorded");

    expect(await token.balanceOf(bridge.address)).to.equal(300n);

    const oneEthCompat = 1_000_000_000n;
    await expect(
      router.connect(user).deposit(
        ethers.constants.AddressZero,
        oneEthCompat,
        ethers.utils.hexZeroPad("0x07", 32),
        u32ToBytes32(1002),
        { value: oneEthCompat }
      )
    ).to.not.be.reverted;

    expect(await weth.balanceOf(bridge.address)).to.equal(oneEthCompat);
    expect(await bridge.pendingDepositCount()).to.equal(2n);

    await expect(
      bridge.connect(user).recordDepositFromGateway(
        token.address,
        l2TokenId,
        1n,
        ethers.utils.hexZeroPad("0x01", 32),
        u32ToBytes32(1003)
      )
    ).to.be.revertedWithCustomError(bridge, "UnauthorizedGateway");
  });

  describe("deposit token mapping admission", function () {
    let owner: any;
    let user: any;
    let router: any;
    let bridge: any;
    let erc20Gateway: any;
    let weth: any;
    let psy: any;
    let usdt: any;
    const shieldAddress = u32ToBytes32(42);
    const noteCommitment = u32ToBytes32(1001);

    beforeEach(async function () {
      [owner, user] = await ethers.getSigners();
      ({ router, bridge, erc20Gateway, weth } = await deployCoreSystem(owner.address, owner.address));
      const factory = await ethers.getContractFactory("MockERC20");
      psy = await factory.deploy("PSY", "PSY");
      usdt = await factory.deploy("pUSDT", "pUSDT");
      await psy.deployed();
      await usdt.deployed();
      await router.setTokenMapping(psy.address, u32ToBytes32(0));
      await router.setTokenMapping(usdt.address, u32ToBytes32(4));
      for (const token of [psy, usdt]) {
        await configureFlowToken(bridge, token.address);
        await token.mint(user.address, 1000);
        await token.connect(user).approve(erc20Gateway.address, 1000);
      }
      await configureFlowToken(bridge, ethers.constants.AddressZero);
    });

    it("rejects an unmapped native deposit instead of recording PSY id zero", async function () {
      await expect(router.connect(user).deposit(
        ethers.constants.AddressZero, 100, shieldAddress, noteCommitment, { value: 100 }
      )).to.be.reverted;
      expect(await bridge.pendingDepositCount()).to.equal(0);
      expect(await weth.balanceOf(bridge.address)).to.equal(0);
    });

    it("rejects an unmapped ERC20 even if the Bridge flow configuration allows it", async function () {
      const factory = await ethers.getContractFactory("MockERC20");
      const unknown = await factory.deploy("Unknown", "UNKNOWN");
      await unknown.deployed();
      await configureFlowToken(bridge, unknown.address);
      await unknown.mint(user.address, 100);
      await unknown.connect(user).approve(erc20Gateway.address, 100);
      await expect(router.connect(user).deposit(
        unknown.address, 100, shieldAddress, noteCommitment
      )).to.be.reverted;
      expect(await unknown.balanceOf(user.address)).to.equal(100);
      expect(await bridge.pendingDepositCount()).to.equal(0);
    });

    it("rejects a stale forward mapping after another token takes its id", async function () {
      await router.setTokenMapping(psy.address, u32ToBytes32(4));
      await expect(router.connect(user).deposit(
        usdt.address, 100, shieldAddress, noteCommitment
      )).to.be.reverted;
      expect(await usdt.balanceOf(user.address)).to.equal(1000);
      expect(await bridge.pendingDepositCount()).to.equal(0);
    });

    it("rejects the all-zero native mapping even when its reverse is also zero", async function () {
      await router.setTokenMapping(ethers.constants.AddressZero, u32ToBytes32(0));
      await expect(router.connect(user).deposit(
        ethers.constants.AddressZero, 100, shieldAddress, noteCommitment, { value: 100 }
      )).to.be.reverted;
      expect(await bridge.pendingDepositCount()).to.equal(0);
      expect(await weth.balanceOf(bridge.address)).to.equal(0);
    });

    it("continues to accept the configured PSY id zero and pUSDT id four", async function () {
      for (const token of [psy, usdt]) {
        await expect(router.connect(user).deposit(
          token.address, 100, shieldAddress, noteCommitment
        )).to.emit(bridge, "DepositRecorded");
        expect(await token.balanceOf(bridge.address)).to.equal(100);
      }
      expect(await bridge.pendingDepositCount()).to.equal(2);
    });
  });
});
