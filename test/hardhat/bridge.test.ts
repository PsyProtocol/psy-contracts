import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
import { buildBridgeWindow, registerWithdrawal, word } from "./helpers/withdrawalClaim";

describe("Bridge atomic withdrawal orchestration (mock verifier, not cryptographic acceptance)", function () {
  it("disables direct recordDeposit entrypoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address);
    await expect(bridge.connect(user).recordDeposit(owner.address, 250n, word(123), word(3001)))
      .to.be.revertedWithCustomError(bridge, "DirectDepositDisabled");
  });

  it("registers a pending withdrawal before a separate permissionless claim", async function () {
    const [owner, user, keeper] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Mock", "MOCK");
    await configureFlowToken(bridge, token.address);
    await token.mint(bridge.address, 777);
    const nonce = await registerWithdrawal({ bridge, stateManager, recipient: user.address, token: token.address, amount: 777n, nonce: 42n });
    expect(await token.balanceOf(user.address)).to.equal(0);
    expect(await bridge.claimedNullifiers(nonce)).to.equal(true);
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(777);
    await bridge.connect(keeper).claimPendingWithdrawal(nonce);
    expect(await token.balanceOf(user.address)).to.equal(777);
    expect((await bridge.pendingWithdrawals(nonce)).amount).to.equal(0);
  });

  it("rejects duplicate nullifiers and rolls the checkpoint back", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address);
    await configureFlowToken(bridge, owner.address);
    const withdrawal = { bridge, stateManager, recipient: user.address, token: owner.address, amount: 333n, nonce: 77n };
    await registerWithdrawal(withdrawal);
    await expect(registerWithdrawal(withdrawal)).to.be.revertedWithCustomError(bridge, "NullifierAlreadyClaimed");
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(1);
    expect(await bridge.totalWithdrawalAmount(owner.address)).to.equal(333);
  });

  it("rejects a destination absent from the configured chain set", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address);
    const args = await buildBridgeWindow(stateManager, bridge, [{ recipient: user.address, token: owner.address, amount: 444n, nonce: 78n, destinationChainIndex: 1 }]);
    await expect(stateManager.applyBridgeWindow(...args)).to.be.reverted;
    expect(await bridge.claimedNullifiers(word(78))).to.equal(false);
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(0);
  });

  it("rejects a withdrawal opening bound to another checkpoint", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager } = await deployCoreSystem(owner.address);
    const args = await buildBridgeWindow(stateManager, bridge, [{ recipient: user.address, token: owner.address, amount: 555n, nonce: 79n }]);
    const opening = args[3] as string;
    args[3] = ethers.utils.hexConcat([ethers.utils.hexDataSlice(opening, 0, 64), word(2), ethers.utils.hexDataSlice(opening, 96)]);
    await expect(stateManager.applyBridgeWindow(...args)).to.be.revertedWithCustomError(stateManager, "InvalidCheckpointContinuity");
    expect(await bridge.claimedNullifiers(word(79))).to.equal(false);
  });
});
