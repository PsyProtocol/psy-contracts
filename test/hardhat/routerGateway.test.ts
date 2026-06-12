import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";

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
});
