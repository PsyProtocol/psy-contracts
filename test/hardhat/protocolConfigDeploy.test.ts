import { expect } from "chai";
import hre, { deployments, ethers } from "hardhat";
import { localFlowLimitConfig } from "../../deploy/003b_initialize_bridge_flow_limits";
import gatewaysDeploy from "../../deploy/004_deploy_gateways";
import wireCoreDeploy from "../../deploy/006_wire_core";
import { protocolConfig } from "../../protocol-config";
import { ensureHardhatDeploymentChainId, getContractAddress, waitForContractDeployment } from "./helpers/deploySystem";

describe("protocol-config external contract deployments", function () {
  it("scales every local flow limit using the configured token or native precision", function () {
    for (const decimals of [6, 9, 18]) {
      const config = localFlowLimitConfig(decimals);
      expect(ethers.utils.formatUnits(ethers.BigNumber.from(config.smallWithdrawalMax).add(1), decimals)).to.equal("50000.0");
      expect(ethers.utils.formatUnits(ethers.BigNumber.from(config.mediumWithdrawalMax).add(1), decimals)).to.equal("100000.0");
      expect(ethers.utils.formatUnits(config.totalWithdrawalCap, decimals)).to.equal("100000000000000000000.0");
      expect(ethers.BigNumber.from(config.totalWithdrawalCap).lte(ethers.BigNumber.from(2).pow(128).sub(1))).to.equal(true);
      expect(ethers.utils.formatUnits(config.depositCap, decimals)).to.equal("10000000.0");
    }
    expect(localFlowLimitConfig(protocolConfig.tokens.USDT.decimals).totalWithdrawalCap).to.equal((10n ** 26n).toString());
    expect(localFlowLimitConfig(protocolConfig.tokens.PSY.decimals).totalWithdrawalCap).to.equal((10n ** 29n).toString());
    expect(localFlowLimitConfig(protocolConfig.chains.localhost.nativeCurrency.decimals).totalWithdrawalCap).to.equal((10n ** 38n).toString());
  });

  it("initializes both token mappings when the PSY L2 contract id is zero", async function () {
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["state_manager", "bridge", "router"]);
    await gatewaysDeploy(hre);

    const router = await ethers.getContractAt("Router", (await deployments.get("Router")).address);
    const token = (await deployments.get("PsyToken")).address;
    const id = protocolConfig.tokens.PSY.l2TokenContractId;
    expect(id).to.equal(ethers.constants.HashZero);
    expect(await router.l1ToL2Token(token)).to.equal(id);
    expect(await router.l2ToL1Token(id)).to.equal(ethers.constants.AddressZero);

    await wireCoreDeploy(hre);
    expect(await router.l1ToL2Token(token)).to.equal(id);
    expect(await router.l2ToL1Token(id)).to.equal(token);

    await wireCoreDeploy(hre);
    expect(await router.l2ToL1Token(id)).to.equal(token);
  });

  it("uses configured WETH and token addresses instead of deploying local mocks", async function () {
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["state_manager", "bridge", "router"]);

    const [deployer] = await ethers.getSigners();
    const wethFactory = await ethers.getContractFactory("WETH9");
    const externalWeth = await wethFactory.deploy();
    await waitForContractDeployment(externalWeth);

    const usdtFactory = await ethers.getContractFactory("USDTToken");
    const externalUsdt = await usdtFactory.deploy(deployer.address, 1_000_000);
    await waitForContractDeployment(externalUsdt);

    const chain = protocolConfig.chains.localhost;
    const usdtDeployment = protocolConfig.tokens.USDT.deployments.localhost;
    if (!usdtDeployment) throw new Error("localhost USDT deployment config missing");

    const previousWeth = chain.wethAddress;
    const previousUsdt = usdtDeployment.l1Address;
    const externalWethAddress = await getContractAddress(externalWeth);
    const externalUsdtAddress = await getContractAddress(externalUsdt);
    chain.wethAddress = externalWethAddress;
    usdtDeployment.l1Address = externalUsdtAddress;

    try {
      await gatewaysDeploy(hre);
      await wireCoreDeploy(hre);

      expect((await deployments.get("WETH9")).address).to.equal(externalWethAddress);
      expect((await deployments.get("USDTToken")).address).to.equal(externalUsdtAddress);

      const ethGateway = await ethers.getContractAt("ETHGateway", (await deployments.get("ETHGateway")).address);
      expect(await ethGateway.weth()).to.equal(externalWethAddress);

      const router = await ethers.getContractAt("Router", (await deployments.get("Router")).address);
      expect(await router.l1ToL2Token(externalUsdtAddress)).to.equal(protocolConfig.tokens.USDT.l2TokenContractId);
    } finally {
      chain.wethAddress = previousWeth;
      usdtDeployment.l1Address = previousUsdt;
    }
  });
});
