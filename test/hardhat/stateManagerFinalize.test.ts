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
    await expect(sm.applyBridgeWindow(...window)).to.be.revertedWithCustomError(sm, "InvalidCheckpointContinuity");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(1);
    window[0] = ZERO_PROOF;
    await expect(sm.applyBridgeWindow(...window)).to.be.revertedWithCustomError(sm, "InvalidProof");
  });

  it("accepts bootstrap identity and rejects an omitted window finalization proof", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address);
    const bootstrap = await buildBridgeWindow(sm, bridge, [], 0n);
    await expect(sm.applyBridgeWindow(...bootstrap)).to.not.emit(sm, "Finalized");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
    const window = await buildBridgeWindow(sm, bridge);
    window[2] = ZERO_PROOF;
    await expect(sm.applyBridgeWindow(...window)).to.be.reverted;
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
  });

  it("rejects endpoint substitution and a truncated window finalization opening before effects", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address);
    for (const index of [30, 34]) {
      const window = await buildBridgeWindow(sm, bridge);
      const bytes = ethers.utils.arrayify(window[3]);
      bytes[index * 32 + 31] ^= 1;
      window[3] = ethers.utils.hexlify(bytes);
      await expect(sm.applyBridgeWindow(...window)).to.be.reverted;
      expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
      expect(await bridge.provedDepositCount()).to.equal(0);
    }
    const noncanonical = await buildBridgeWindow(sm, bridge);
    const limb = ethers.utils.arrayify(noncanonical[3]);
    limb[35 * 32] = 0xff;
    noncanonical[3] = ethers.utils.hexlify(limb);
    await expect(sm.applyBridgeWindow(...noncanonical)).to.be.reverted;
    const window = await buildBridgeWindow(sm, bridge);
    window[3] = ethers.utils.hexDataSlice(window[3], 0, ethers.utils.arrayify(window[3]).length - 32);
    await expect(sm.applyBridgeWindow(...window)).to.be.reverted;
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
  });
});
