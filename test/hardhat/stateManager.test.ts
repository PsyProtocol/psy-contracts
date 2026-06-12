import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
import { DUMMY_GNARK_PROOF } from "./helpers/mockProof";

describe("StateManager", function () {
  it("separates bridge and proposer permissions", async function () {
    const [owner, , proposer, other] = await ethers.getSigners();
    const { acl, stateManager: sm } = await deployCoreSystem(owner.address, proposer.address);

    await expect(
      sm.connect(other).finalize(
        DUMMY_GNARK_PROOF,
        ethers.constants.HashZero,
        [ethers.constants.HashZero, ethers.constants.HashZero],
        ethers.constants.HashZero,
        0,
        1,
        new Array(9).fill(ethers.constants.HashZero),
        new Array(9).fill(ethers.constants.HashZero)
      )
    ).to.be.revertedWithCustomError(sm, "OnlyProposer");

    await acl.grantRole(await acl.PROPOSER_ROLE(), other.address);
    await expect(
      sm.connect(other).finalize(
        "0x",
        ethers.constants.HashZero,
        [ethers.constants.HashZero, ethers.constants.HashZero],
        ethers.constants.HashZero,
        0,
        1,
        new Array(9).fill(ethers.constants.HashZero),
        new Array(9).fill(ethers.constants.HashZero)
      )
    ).to.be.revertedWithCustomError(sm, "InvalidProof");

    await expect(
      sm.connect(other).finalize(
        DUMMY_GNARK_PROOF,
        ethers.constants.HashZero,
        [ethers.constants.HashZero, ethers.constants.HashZero],
        ethers.constants.HashZero,
        0,
        1,
        new Array(9).fill(ethers.constants.HashZero),
        new Array(9).fill(ethers.constants.HashZero)
      )
    ).to.not.be.reverted;
  });
});
