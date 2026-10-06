import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
import { registerWithdrawal } from "./helpers/withdrawalClaim";

describe("Multicall3 claim", function () {
  it("batches pending withdrawal claims through Multicall3", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, stateManager: sm } = await deployCoreSystem(owner.address, owner.address);

    const M = await ethers.getContractFactory("Multicall3");
    const multicall = await M.deploy();
    await multicall.deployed();

    const T = await ethers.getContractFactory("MockERC20");
    const token = await T.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);
    const amount = 99n;
    const nonce = 9n;
    await token.mint(bridge.address, amount);

    const nullifier = await registerWithdrawal({ bridge, stateManager: sm,
      recipient: user.address, token: token.address, amount, nonce });
    const settleCallData = bridge.interface.encodeFunctionData("claimPendingWithdrawal", [nullifier]);
    await multicall.aggregate3([
      {
        target: bridge.address,
        allowFailure: false,
        callData: settleCallData,
      },
    ]);

    expect(await token.balanceOf(user.address)).to.equal(amount);
  });
});
