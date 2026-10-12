import { expect } from "chai";
import { ethers } from "hardhat";
import { configureFlowToken, deployCoreSystem } from "./helpers/deploySystem";
import { installWithdrawalToken, registerWithdrawal } from "./helpers/withdrawalClaim";

describe("Multicall3 claim", function () {
  it("batches pending withdrawal claims through Multicall3", async function () {
    const { bridge, stateManager: sm, verifier } = await deployCoreSystem(owner.address, owner.address);

    const M = await ethers.getContractFactory("Multicall3");
    const multicall = await M.deploy();
    await multicall.deployed();

    const T = await ethers.getContractFactory("MockERC20");
    const token = await T.deploy("Mock", "MOCK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);
    await installWithdrawalToken(bridge, verifier, sm, token.address, 1);
    const amount = 99n;
    const nonce = 9n;
    await token.mint(bridge.address, amount);

    const record = await registerWithdrawal({ bridge, stateManager: sm,
      recipient: user.address, tokenContractId: 1, amount, nonce });
    const settleCallData = bridge.interface.encodeFunctionData(
      "claimPendingWithdrawal", [record.senderUserId, record.tokenContractId, record.nonce],
    );
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
