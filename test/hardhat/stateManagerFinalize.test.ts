import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
import { buildBridgeOpeningCall, word, ZERO_PROOF } from "./helpers/withdrawalClaim";

describe("StateManager.applyBridgeOpening orchestration (mock verifier only)", function () {
  it("advances checkpoint and deposit cursors together", async function () {
    const [owner, proposer] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address, proposer.address);
    const window = await buildBridgeOpeningCall(sm, bridge, [], 10n);
    await expect(sm.connect(proposer).applyBridgeOpening(...window)).to.emit(sm, "Finalized");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(10);
    expect(await sm.lastVerifiedCheckpointRoot()).to.equal(word(10));
    expect(await sm.depositSubtreeRoot()).to.equal(await bridge.depositRoot());
    expect(await sm.depositCount()).to.equal(await bridge.provedDepositCount());
    expect(await sm.lastVerifiedDepositTreeRoot()).to.equal(ethers.constants.HashZero);
    expect(await sm.lastVerifiedWithdrawalTreeRoot()).to.equal(ethers.constants.HashZero);
  });

  it("requires opening verification and checkpoint continuity on positive-span replay", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge, verifier } = await deployCoreSystem(owner.address);
    await sm.applyBridgeOpening(...await buildBridgeOpeningCall(sm, bridge));
    const window = await buildBridgeOpeningCall(sm, bridge, [], 1n);
    await verifier.setShouldVerify(false);
    await expect(sm.applyBridgeOpening(...window)).to.be.revertedWith("invalid proof");
    await verifier.setShouldVerify(true);
    await expect(sm.applyBridgeOpening(...window)).to.be.revertedWithCustomError(sm, "InvalidCheckpointContinuity");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(1);
    window[0] = ZERO_PROOF;
    await expect(sm.applyBridgeOpening(...window)).to.be.revertedWithCustomError(sm, "InvalidProof");
  });

  it("accepts bootstrap identity and rejects an omitted window finalization proof", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address);
    const bootstrap = await buildBridgeOpeningCall(sm, bridge, [], 0n);
    await expect(sm.applyBridgeOpening(...bootstrap)).to.not.emit(sm, "Finalized");
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
    const window = await buildBridgeOpeningCall(sm, bridge);
    window[0] = ZERO_PROOF;
    await expect(sm.applyBridgeOpening(...window)).to.be.reverted;
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
  });

  it("rejects a wrong version, a bad count, a noncanonical limb, and a truncated opening before effects", async function () {
    const [owner] = await ethers.getSigners();
    const { stateManager: sm, bridge } = await deployCoreSystem(owner.address);
    // Header word 0 (version=4) and word 14 (reward count with no reward section) both reject.
    for (const index of [0, 14]) {
      const window = await buildBridgeOpeningCall(sm, bridge);
      const bytes = ethers.utils.arrayify(window[1]);
      bytes[index * 32 + 31] ^= 1;
      window[1] = ethers.utils.hexlify(bytes);
      await expect(sm.applyBridgeOpening(...window)).to.be.reverted;
      expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
      expect(await bridge.provedDepositCount()).to.equal(0);
    }
    // A checkpoint-root limb outside the Goldilocks field is rejected as noncanonical.
    const noncanonical = await buildBridgeOpeningCall(sm, bridge);
    const limb = ethers.utils.arrayify(noncanonical[1]);
    limb[3 * 32] = 0xff;
    noncanonical[1] = ethers.utils.hexlify(limb);
    await expect(sm.applyBridgeOpening(...noncanonical)).to.be.reverted;
    const window = await buildBridgeOpeningCall(sm, bridge);
    window[1] = ethers.utils.hexDataSlice(window[1], 0, ethers.utils.arrayify(window[1]).length - 32);
    await expect(sm.applyBridgeOpening(...window)).to.be.reverted;
    expect(await sm.lastFinalizedCheckpointId()).to.equal(0);
  });
});
