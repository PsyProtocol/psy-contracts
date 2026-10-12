import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
import { buildBridgeOpeningCall, installWithdrawalToken, registerWithdrawal, scopedKey, word } from "./helpers/withdrawalClaim";

describe("Bridge atomic withdrawal orchestration (mock verifier, not cryptographic acceptance)", function () {
  it("disables direct recordDeposit entrypoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address);
    await expect(bridge.connect(user).recordDeposit(owner.address, 250n, word(123), word(3001)))
      .to.be.revertedWithCustomError(bridge, "DirectDepositDisabled");
  });

  it("registers a pending withdrawal before a separate permissionless claim", async function () {
    const [owner, user, keeper] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Mock", "MOCK");
    await configureFlowToken(bridge, token.address);
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);
    await token.mint(bridge.address, 777);
    const record = await registerWithdrawal({ bridge, stateManager, recipient: user.address, tokenContractId: 1, amount: 777n, nonce: 42n });
    expect(await token.balanceOf(user.address)).to.equal(0);
    expect(await bridge.claimedWithdrawals(record.key)).to.equal(false);
    expect((await bridge.scopedPendingWithdrawals(record.key)).amount).to.equal(777);
    await bridge.connect(keeper).claimPendingWithdrawal(record.senderUserId, record.tokenContractId, record.nonce);
    expect(await token.balanceOf(user.address)).to.equal(777);
    expect(await bridge.claimedWithdrawals(record.key)).to.equal(true);
    expect((await bridge.scopedPendingWithdrawals(record.key)).amount).to.equal(0);
  });

  it("skips an already registered withdrawal without consuming it again", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Mock", "MOCK");
    await configureFlowToken(bridge, token.address);
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);
    const withdrawal = { bridge, stateManager, recipient: user.address, tokenContractId: 1, amount: 333n, nonce: 77n };
    const record = await registerWithdrawal(withdrawal);
    const pending = await bridge.scopedPendingWithdrawals(record.key);
    await expect(registerWithdrawal(withdrawal))
      .to.emit(bridge, "WithdrawalSkipped")
      .withArgs(record.key, 1);
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(1);
    expect(await bridge.claimedWithdrawals(record.key)).to.equal(true);
    const pendingAfter = await bridge.scopedPendingWithdrawals(record.key);
    expect(pendingAfter.amount).to.equal(pending.amount);
    expect(pendingAfter.claimableAt).to.equal(pending.claimableAt);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(333);
  });

  it("rejects a destination absent from the configured chain set", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Mock", "MOCK");
    await configureFlowToken(bridge, token.address);
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);
    const args = await buildBridgeOpeningCall(stateManager, bridge, [{ recipient: user.address, tokenContractId: 1, amount: 444n, nonce: 78n, destinationChainIndex: 1 }]);
    await expect(stateManager.applyBridgeOpening(...args)).to.be.reverted;
    expect(await bridge.claimedWithdrawals(scopedKey(0, 1, word(78)))).to.equal(false);
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(0);
  });

  it("rejects a withdrawal opening bound to another checkpoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Mock", "MOCK");
    await configureFlowToken(bridge, token.address);
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);
    const args = await buildBridgeOpeningCall(stateManager, bridge, [{ recipient: user.address, tokenContractId: 1, amount: 555n, nonce: 79n }]);
    const opening = args[1] as string;
    args[1] = ethers.utils.hexConcat([ethers.utils.hexDataSlice(opening, 0, 64), word(2), ethers.utils.hexDataSlice(opening, 96)]);
    await expect(stateManager.applyBridgeOpening(...args)).to.be.revertedWithCustomError(stateManager, "InvalidCheckpointContinuity");
    expect(await bridge.claimedWithdrawals(scopedKey(0, 1, word(79)))).to.equal(false);
  });
});
