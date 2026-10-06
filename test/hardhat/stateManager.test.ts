import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
import { buildBridgeWindow } from "./helpers/withdrawalClaim";

describe("StateManager orchestration permissions", function () {
  it("checks proposer authorization before proof admission", async function () {
    const [owner, proposer, other] = await ethers.getSigners();
    const { acl, stateManager: sm, bridge, verifier } = await deployCoreSystem(owner.address, proposer.address);
    const window = await buildBridgeWindow(sm, bridge);
    await expect(sm.connect(other).applyBridgeWindow(...window)).to.be.revertedWithCustomError(sm, "OnlyProposer");
    await acl.grantRole(await acl.PROPOSER_ROLE(), other.address);
    await verifier.setShouldVerify(false);
    await expect(sm.connect(other).applyBridgeWindow(...window)).to.be.revertedWith("invalid proof");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
    await verifier.setShouldVerify(true);
    await sm.connect(other).applyBridgeWindow(...window);
    expect(await sm.lastFinalizedCheckpointId()).to.equal(1);
  });
});
