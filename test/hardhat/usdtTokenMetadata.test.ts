import { expect } from "chai";
import { ethers } from "hardhat";
import { getTokenDisplaySymbol, protocolConfig } from "../../protocol-config";
import { waitForContractDeployment } from "./helpers/deploySystem";

const INITIAL_SUPPLY = "1000000000000000"; // 1 billion tokens with 6 decimals.

describe("pUSDT testnet token", function () {
  for (const network of ["sepolia", "bscTestnet", "baseSepolia"] as const) {
    it(`deploys pUSDT from the ${network} token configuration`, async function () {
      const config = protocolConfig.tokens.USDT;
      const deployment = config.deployments[network];
      expect(deployment?.deployName).to.equal("USDTToken");
      expect(deployment?.l1Address).to.equal(undefined);
      expect(config.decimals).to.equal(6);

      // Use the same deployment name and supply calculation as 004_deploy_gateways.
      const [holder] = await ethers.getSigners();
      const factory = await ethers.getContractFactory(deployment!.deployName!);
      const supply = (1_000_000_000n * 10n ** BigInt(config.decimals)).toString();
      const token = await factory.deploy(holder.address, supply);
      await waitForContractDeployment(token);

      expect(await token.name()).to.equal("Psy USDT");
      expect(await token.symbol()).to.equal("pUSDT");
      expect(await token.symbol()).to.equal(getTokenDisplaySymbol("USDT", network));
      expect(await token.decimals()).to.equal(6);
      expect(await token.owner()).to.equal(holder.address);
      expect(await token.totalSupply()).to.equal(INITIAL_SUPPLY);
      expect(await token.balanceOf(holder.address)).to.equal(INITIAL_SUPPLY);
    });
  }

  it("preserves owner-only minting and ownership transfer", async function () {
    const [holder, nextOwner, recipient] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("USDTToken");
    const token = await factory.deploy(holder.address, INITIAL_SUPPLY);
    await waitForContractDeployment(token);

    await expect(token.connect(recipient).mint(recipient.address, 1))
      .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
      .withArgs(recipient.address);
    await token.mint(recipient.address, 100);
    await token.transferOwnership(nextOwner.address);
    await expect(token.mint(recipient.address, 1))
      .to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount")
      .withArgs(holder.address);
    await token.connect(nextOwner).mint(recipient.address, 200);

    expect(await token.balanceOf(recipient.address)).to.equal(300);
    expect(await token.totalSupply()).to.equal("1000000000000300");
  });

  it("preserves transfers without changing supply", async function () {
    const [holder, recipient] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("USDTToken");
    const token = await factory.deploy(holder.address, INITIAL_SUPPLY);
    await waitForContractDeployment(token);

    await token.transfer(recipient.address, 1_000_000);

    expect(await token.balanceOf(recipient.address)).to.equal(1_000_000);
    expect(await token.balanceOf(holder.address)).to.equal("999999999000000");
    expect(await token.totalSupply()).to.equal(INITIAL_SUPPLY);
  });

  it("keeps the internal USDT identity and external mainnet asset unchanged", function () {
    expect(protocolConfig.tokens.USDT.symbol).to.equal("USDT");
    expect(protocolConfig.tokens.USDT.l2TokenContractId).to.equal(
      "0x0000000000000000000000000000000000000000000000000000000000000004",
    );
    expect(protocolConfig.tokens.USDT.deployments.ethereum).to.deep.equal({
      l1Address: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
      displaySymbol: "USDT",
    });
    expect(getTokenDisplaySymbol("USDT", "ethereum")).to.equal("USDT");
  });
});
