import { expect } from "chai";
import { ethers, network } from "hardhat";
import {
  configureFlowToken,
  defaultFlowConfig,
  deployCoreSystem,
  tokenSetHash,
} from "./helpers/deploySystem";
import { buildBridgeOpeningCall, installWithdrawalToken, registerWithdrawal, scopedKey, word } from "./helpers/withdrawalClaim";

describe("Bridge per-token flow limits", function () {
  it("enforces deposit minimum, deposit cap, and token isolation", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, router, erc20Gateway } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockERC20");
    const tokenA = await factory.deploy("Token A", "A");
    const tokenB = await factory.deploy("Token B", "B");
    await tokenA.deployed();
    await tokenB.deployed();

    for (const token of [tokenA, tokenB]) {
      await router.setTokenMapping(token.address, ethers.utils.hexZeroPad(token.address, 32));
      await configureFlowToken(bridge, token.address, {
        minDepositAmount: 100,
        depositCap: 500,
      });
      await token.mint(user.address, 2_000);
      await token.connect(user).approve(erc20Gateway.address, 2_000);
    }

    await router.connect(user).deposit(tokenA.address, 400, ethers.constants.HashZero, ethers.constants.HashZero);
    await expect(
      router.connect(user).deposit(tokenA.address, 101, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(bridge, "DepositCapExceeded");
    expect(await tokenA.balanceOf(bridge.address)).to.equal(400);

    await expect(
      router.connect(user).deposit(tokenB.address, 99, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(bridge, "DepositBelowMinimum");
    await router.connect(user).deposit(tokenB.address, 250, ethers.constants.HashZero, ethers.constants.HashZero);
    expect(await tokenB.balanceOf(bridge.address)).to.equal(250);
  });

  it("updates a token config with stale-hash protection", async function () {
    const [owner] = await ethers.getSigners();
    const { bridge } = await deployCoreSystem(owner.address, owner.address);
    const token = ethers.Wallet.createRandom().address;
    await configureFlowToken(bridge, token, { depositCap: 500 });

    const oldHash = await bridge.getTokenFlowConfigHash(token);
    const next = defaultFlowConfig({ depositCap: 1_000 });
    await bridge.setTokenFlowConfig(token, next, oldHash);
    expect((await bridge.getTokenFlowConfig(token)).depositCap).to.equal(1_000);
    await expect(bridge.setTokenFlowConfig(token, next, oldHash)).to.be.revertedWithCustomError(
      bridge,
      "StaleConfigHash",
    );
  });

  it("rejects fee-on-transfer deposits without recording custody or a leaf", async function () {
    const [owner, user] = await ethers.getSigners();
    const { bridge, router, erc20Gateway } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockFeeOnTransferERC20");
    const token = await factory.deploy();
    await token.deployed();
    await router.setTokenMapping(token.address, ethers.utils.hexZeroPad(token.address, 32));
    await configureFlowToken(bridge, token.address);
    await token.mint(user.address, 1_000);
    await token.connect(user).approve(erc20Gateway.address, 1_000);

    await expect(
      router.connect(user).deposit(token.address, 100, ethers.constants.HashZero, ethers.constants.HashZero),
    ).to.be.revertedWithCustomError(erc20Gateway, "UnsupportedTokenTransfer");
    expect(await token.balanceOf(bridge.address)).to.equal(0);
    expect(await bridge.pendingDepositCount()).to.equal(0);
  });

  it("accumulates lifetime withdrawal amount across pending and settled withdrawals without decrementing", async function () {
    const [owner, recipient, keeper] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 100,
      mediumWithdrawalMax: 300,
      totalWithdrawalCap: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 0,
      largeWithdrawalDelay: 3_600,
    });
    await token.mint(bridge.address, 601);
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);

    const firstClaim = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 300n, nonce: 9001n,
    });
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(300);
    await bridge.connect(keeper).claimPendingWithdrawal(firstClaim.senderUserId, firstClaim.tokenContractId, firstClaim.nonce);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(300);

    const secondClaim = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 200n, nonce: 9002n,
    });
    expect((await bridge.scopedPendingWithdrawals(secondClaim.key)).amount).to.equal(200);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(500);

    const crossingClaim = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 1n, nonce: 9003n,
    });
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(501);
    expect((await bridge.scopedPendingWithdrawals(crossingClaim.key)).claimableAt).to.be.gt(
      (await ethers.provider.getBlock("latest")).timestamp,
    );
  });

  it("lets only the initialized Timelock executor force-claim the exact stored withdrawal", async function () {
    const [owner, recipient, other] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    const config = await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 10,
      mediumWithdrawalMax: 20,
      totalWithdrawalCap: 20,
      largeWithdrawalDelay: 3_600,
    });
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);
    const timelock = await (await ethers.getContractFactory("ExecutorWithTimelock")).deploy(
      owner.address, 1, 100, 1, 100,
    );
    await timelock.deployed();
    await bridge.initializeWithdrawalTotals(
      [token.address], [config], [0], tokenSetHash([token.address]), timelock.address,
    );
    expect(await bridge.withdrawalForceClaimExecutor()).to.equal(timelock.address);
    expect(await bridge.withdrawalTotalsTokenSetHash()).to.equal(tokenSetHash([token.address]));
    await token.mint(bridge.address, 30);
    const claim = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 30n, nonce: 0xa1n,
    });

    for (const caller of [owner, other]) {
      await expect(bridge.connect(caller).forceClaimWithdrawal(claim.senderUserId, claim.tokenContractId, claim.nonce))
        .to.be.revertedWithCustomError(bridge, "UnauthorizedWithdrawalForceClaimExecutor")
        .withArgs(caller.address);
    }
    await bridge.setTokenPauseFlags(token.address, 4);
    const data = bridge.interface.encodeFunctionData(
      "forceClaimWithdrawal", [claim.senderUserId, claim.tokenContractId, claim.nonce],
    );
    let executionTime = (await ethers.provider.getBlock("latest")).timestamp + 2;
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime))
      .to.be.revertedWith("FAILED_ACTION_EXECUTION");
    expect((await bridge.scopedPendingWithdrawals(claim.key)).amount).to.equal(30);

    await bridge.setTokenPauseFlags(token.address, 0);
    executionTime = (await ethers.provider.getBlock("latest")).timestamp + 2;
    await timelock.queueTransaction(bridge.address, 0, "", data, executionTime);
    await network.provider.send("evm_setNextBlockTimestamp", [executionTime]);
    await expect(timelock.executeTransaction(bridge.address, 0, "", data, executionTime))
      .to.emit(bridge, "WithdrawalForceClaimed")
      .withArgs(claim.key, timelock.address);
    expect(await token.balanceOf(recipient.address)).to.equal(30);
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(30);
    expect((await bridge.scopedPendingWithdrawals(claim.key)).amount).to.equal(0);
  });

  it("uses total withdrawal cap for large delays and keeps token totals isolated", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address, owner.address);
    const factory = await ethers.getContractFactory("MockERC20");
    const tokenA = await factory.deploy("Token A", "A");
    const tokenB = await factory.deploy("Token B", "B");
    await tokenA.deployed();
    await tokenB.deployed();
    for (const token of [tokenA, tokenB]) {
      await configureFlowToken(bridge, token.address, {
        smallWithdrawalMax: 100,
        mediumWithdrawalMax: 150,
        totalWithdrawalCap: 200,
        smallWithdrawalDelay: 0,
        mediumWithdrawalDelay: 0,
        largeWithdrawalDelay: 3_600,
      });
      await installWithdrawalToken(bridge, verifier, stateManager, token.address, token === tokenA ? 1 : 2);
    }

    await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 100n, nonce: 0x11n,
    });
    const atCap = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 100n, nonce: 0x22n,
    });
    expect((await bridge.scopedPendingWithdrawals(atCap.key)).claimableAt).to.be.lte((await ethers.provider.getBlock("latest")).timestamp);
    const crossingClaim = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount: 1n, nonce: 0x33n,
    });
    expect((await bridge.scopedPendingWithdrawals(crossingClaim.key)).claimableAt).to.be.gt(
      (await ethers.provider.getBlock("latest")).timestamp,
    );
    const tokenBClaim = await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 2, amount: 1n, nonce: 0x44n,
    });
    expect((await bridge.scopedPendingWithdrawals(tokenBClaim.key)).claimableAt).to.be.lte(
      (await ethers.provider.getBlock("latest")).timestamp,
    );
    expect(await bridge.totalWithdrawalAmount(tokenB.address)).to.equal(1);

    const oldHash = await bridge.getTokenFlowConfigHash(tokenA.address);
    await bridge.setTokenFlowConfig(tokenA.address, defaultFlowConfig({
      smallWithdrawalMax: 100,
      mediumWithdrawalMax: 150,
      totalWithdrawalCap: 500,
      smallWithdrawalDelay: 0,
      mediumWithdrawalDelay: 0,
      largeWithdrawalDelay: 3_600,
    }), oldHash);
    expect(await bridge.totalWithdrawalAmount(tokenA.address)).to.equal(201);
  });

  it("keeps pause state outside the config hash and gives Guardian pause-only behavior", async function () {
    const [owner, guardian] = await ethers.getSigners();
    const { bridge, acl } = await deployCoreSystem(owner.address, owner.address);
    const token = ethers.Wallet.createRandom().address;
    await configureFlowToken(bridge, token);
    await acl.grantRole(await acl.GUARDIAN_ROLE(), guardian.address);

    const configHash = await bridge.getTokenFlowConfigHash(token);
    await bridge.connect(guardian).guardianPauseToken(token, 1);
    expect(await bridge.getTokenFlowConfigHash(token)).to.equal(configHash);
    expect((await bridge.getPauseFlags(token)).effectiveFlags).to.equal(1);

    await bridge.connect(guardian).guardianPauseToken(token, 0);
    expect((await bridge.getPauseFlags(token)).effectiveFlags).to.equal(1);
    await expect(bridge.connect(guardian).setTokenPauseFlags(token, 0)).to.be.revertedWithCustomError(
      bridge,
      "UnauthorizedBridgeAdmin",
    );
    await bridge.setTokenPauseFlags(token, 0);
    expect((await bridge.getPauseFlags(token)).effectiveFlags).to.equal(0);
  });
  it("rolls lifetime totals, pending withdrawals and checkpoint back when a later leaf fails", async function () {
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address);
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);
    const nonce = 0x77n;
    const args = await buildBridgeOpeningCall(stateManager, bridge, [
      { recipient: recipient.address, tokenContractId: 1, amount: 123n, nonce },
      { recipient: recipient.address, tokenContractId: 1, amount: 1n, nonce: nonce + 1n },
    ]);
    await expect(stateManager.applyBridgeOpening(...args)).to.be.reverted;
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(0);
    expect(await bridge.claimedWithdrawals(scopedKey(0, 1, word(nonce)))).to.equal(false);
    expect((await bridge.scopedPendingWithdrawals(scopedKey(0, 1, word(nonce)))).amount).to.equal(0);
    expect(await stateManager.lastFinalizedCheckpointId()).to.equal(0);
  });


  it("enforces Goldilocks bounds and rolls lifetime totals and nullifiers back on failed registration", async function () {
    const GOLDILOCKS_PRIME = 18_446_744_069_414_584_321n;
    const [owner, recipient] = await ethers.getSigners();
    const { bridge, stateManager, verifier } = await deployCoreSystem(owner.address, owner.address);
    const token = await (await ethers.getContractFactory("MockERC20")).deploy("Token", "TOK");
    await token.deployed();
    await configureFlowToken(bridge, token.address, {
      smallWithdrawalMax: 5,
      mediumWithdrawalMax: 10,
      totalWithdrawalCap: 10,
    });
    await installWithdrawalToken(bridge, verifier, stateManager, token.address, 1);

    await registerWithdrawal({
      bridge, stateManager, recipient: recipient.address, tokenContractId: 1,
      amount: GOLDILOCKS_PRIME - 1n, nonce: 0x97n,
    });
    expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(GOLDILOCKS_PRIME - 1n);
    for (const [amount, nonce] of [
      [GOLDILOCKS_PRIME, 0x94n],
      [GOLDILOCKS_PRIME + 1n, 0x95n],
    ] as const) {
      await expect(registerWithdrawal({
        bridge, stateManager, recipient: recipient.address, tokenContractId: 1, amount, nonce,
      })).to.be.reverted;
      expect(await bridge.claimedWithdrawals(scopedKey(0, 1, word(nonce)))).to.equal(false);
      expect(await bridge.totalWithdrawalAmount(token.address)).to.equal(GOLDILOCKS_PRIME - 1n);
    }
  });
});
