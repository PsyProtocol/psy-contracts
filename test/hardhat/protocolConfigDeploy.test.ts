import { expect } from "chai";
import hre, { deployments, ethers } from "hardhat";
import gatewaysDeploy from "../../deploy/004_deploy_gateways";
import wireCoreDeploy from "../../deploy/006_wire_core";
import { protocolConfig } from "../../protocol-config";
import { ensureHardhatDeploymentChainId, getContractAddress, waitForContractDeployment } from "./helpers/deploySystem";

describe("protocol-config external contract deployments", function () {
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
