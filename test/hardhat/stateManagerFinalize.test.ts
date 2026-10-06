import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
import { buildBridgeWindow, word, ZERO_PROOF } from "./helpers/withdrawalClaim";

describe("StateManager.applyBridgeWindow orchestration (mock verifier only)", function () {
  it("advances checkpoint and deposit cursors together", async function () {
    const [owner, proposer] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address, proposer.address);
    const window = await buildBridgeWindow(sm, bridge, [], 10n);
    await expect(sm.connect(proposer).applyBridgeWindow(...window)).to.emit(sm, "Finalized");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(10);
    expect(await sm.lastVerifiedCheckpointRoot()).to.equal(word(10));
    expect(await sm.depositSubtreeRoot()).to.equal(await bridge.depositRoot());
    expect(await sm.depositCount()).to.equal(await bridge.provedDepositCount());
    expect(await sm.lastVerifiedDepositTreeRoot()).to.equal(ethers.constants.HashZero);
    expect(await sm.lastVerifiedWithdrawalTreeRoot()).to.equal(ethers.constants.HashZero);
  });

  it("requires deposit verification on positive-span historical replay", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge, batchVerifier, verifier } = await deployCoreSystem(owner.address);
    await sm.applyBridgeWindow(...await buildBridgeWindow(sm, bridge));
    const window = await buildBridgeWindow(sm, bridge, [], 1n);
    await verifier.setShouldVerify(false);
    await expect(sm.applyBridgeWindow(...window)).to.be.revertedWith("invalid proof");
    await verifier.setShouldVerify(true);
    await batchVerifier.setShouldVerify(false);
    await expect(sm.applyBridgeWindow(...window)).to.be.revertedWith("invalid proof");
    await batchVerifier.setShouldVerify(true);
    await expect(sm.applyBridgeWindow(...window)).to.not.emit(sm, "Finalized");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(1);
    window[2] = ZERO_PROOF;
    await expect(sm.applyBridgeWindow(...window)).to.be.revertedWithCustomError(sm, "InvalidProof");
  });

  it("rejects bootstrap replay and omitted finalize evidence", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address);
    const bootstrap = await buildBridgeWindow(sm, bridge, [], 0n);
    await expect(sm.applyBridgeWindow(...bootstrap)).to.be.reverted;
    const window = await buildBridgeWindow(sm, bridge);
    window[0] = ZERO_PROOF;
    await expect(sm.applyBridgeWindow(...window)).to.be.reverted;
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
  });

  it("rejects endpoint substitution and incomplete finalize inputs before effects", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address);
    for (const index of [26, 30, 31]) {
      const window = await buildBridgeWindow(sm, bridge);
      window[1][index] ^= 1n;
      await expect(sm.applyBridgeWindow(...window)).to.be.reverted;
      expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
      expect(await bridge.provedDepositCount()).to.equal(0);
    }
    const window = await buildBridgeWindow(sm, bridge);
    window[1].pop();
    await expect(sm.applyBridgeWindow(...window)).to.be.reverted;
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
  });
});
