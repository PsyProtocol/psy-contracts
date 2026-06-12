import { expect } from "chai";
import { ethers } from "hardhat";

describe("IncrementalMerkleTreeHarness", function () {
  it("appends leaves and updates root", async function () {
    const Factory = await ethers.getContractFactory("IncrementalMerkleTreeHarness");
    const tree = await Factory.deploy();
    await tree.deployed();
    await tree.initializeHarness(4, 8);

    const root0 = await tree.getLatestRoot();
    const tx = await tree.append(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("leaf-0")));
    await tx.wait();
    const root1 = await tree.getLatestRoot();

    expect(root1).to.not.equal(root0);
    expect(await tree.isKnownRoot(root1)).to.equal(true);
  });
});
