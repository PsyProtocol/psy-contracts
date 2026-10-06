import { expect } from "chai";
import { deployments, ethers, getNamedAccounts } from "hardhat";
import {
  atomicDeployPrerequisitesMissing,
  ensureHardhatDeploymentChainId,
  getContractAddress,
  hexZeroPad,
} from "./helpers/deploySystem";
import { buildBridgeWindow, ZERO_PROOF } from "./helpers/withdrawalClaim";

describe("Deployed Permission Configuration", function () {
  it("matches expected permissions after running deploy scripts", async function () {
    if (atomicDeployPrerequisitesMissing()) this.skip();
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["transfer_ownership"]);

    const { admin: adminAddress, proposer: proposerAddress } = await getNamedAccounts();
    const admin = await ethers.getSigner(adminAddress);
    const proposer = await ethers.getSigner(proposerAddress);
    const outsider = (await ethers.getSigners())[2];
    const provider = await ethers.getContractAt("PsyAddressesProvider", (await deployments.get("PsyAddressesProvider")).address);
    const acl = await ethers.getContractAt("PsyACLManager", (await deployments.get("PsyACLManager")).address);
    const sm = await ethers.getContractAt("StateManager", (await deployments.get("StateManager")).address);
    const bridge = await ethers.getContractAt("Bridge", (await deployments.get("Bridge")).address);
    const router = await ethers.getContractAt("Router", (await deployments.get("Router")).address);
    const erc20Gateway = await ethers.getContractAt("ERC20Gateway", (await deployments.get("ERC20Gateway")).address);
    const ethGateway = await ethers.getContractAt("ETHGateway", (await deployments.get("ETHGateway")).address);
    const aclAddress = await getContractAddress(acl);
    const bridgeAddress = await getContractAddress(bridge);
    const stateManagerAddress = await getContractAddress(sm);
    const routerAddress = await getContractAddress(router);
    const erc20GatewayAddress = await getContractAddress(erc20Gateway);
    const ethGatewayAddress = await getContractAddress(ethGateway);

    // 1) Provider wiring after deployment
    expect(await provider["getAddress(bytes32)"](await provider.ACL_MANAGER_ID())).to.equal(aclAddress);
    expect(await provider["getAddress(bytes32)"](await provider.BRIDGE_ID())).to.equal(bridgeAddress);
    expect(await provider["getAddress(bytes32)"](await provider.STATE_MANAGER_ID())).to.equal(stateManagerAddress);
    expect(await provider["getAddress(bytes32)"](await provider.ROUTER_ID())).to.equal(routerAddress);
    expect(await provider["getAddress(bytes32)"](await provider.ERC20_GATEWAY_ID())).to.equal(erc20GatewayAddress);
    expect(await provider["getAddress(bytes32)"](await provider.ETH_GATEWAY_ID())).to.equal(ethGatewayAddress);

    // 2) ACL roles assigned by deployment config
    expect(await acl.hasRole(await acl.BRIDGE_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await acl.hasRole(await acl.ROUTER_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await acl.hasRole(await acl.STATE_MANAGER_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await acl.hasRole(await acl.PROPOSER_ROLE(), proposer.address)).to.equal(true);

    // 3) Only owner can mutate provider address book
    await expect(
      provider.connect(outsider).setAddress(await provider.BRIDGE_ID(), outsider.address)
    ).to.be.reverted;
    await expect(
      router.connect(outsider).setTokenMapping(ethers.Wallet.createRandom().address, hexZeroPad("0x01", 32))
    ).to.be.revertedWithCustomError(router, "OnlyRouterAdmin");

    await expect(
      router.connect(admin).setTokenMapping(ethers.Wallet.createRandom().address, hexZeroPad("0x02", 32))
    ).to.not.be.reverted;

    // 4) Proposer gate on the atomic window, and a zero-proof window stays invalid
    const window = await buildBridgeWindow(sm, bridge);
    window[0] = ZERO_PROOF;
    window[2] = ZERO_PROOF;
    window[4] = ZERO_PROOF;
    window[6] = ZERO_PROOF;
    await expect(sm.connect(outsider).applyBridgeWindow(...window)).to.be.revertedWithCustomError(sm, "OnlyProposer");
    await expect(sm.connect(proposer).applyBridgeWindow(...window)).to.be.revertedWithCustomError(sm, "InvalidProof");
  });
});
