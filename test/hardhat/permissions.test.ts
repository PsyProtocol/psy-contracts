import { expect } from "chai";
import { ethers } from "hardhat";
import { deployCoreSystem } from "./helpers/deploySystem";
import { deployProxy } from "./helpers/deployProxy";
import { buildBridgeWindow } from "./helpers/withdrawalClaim";

describe("Permission Matrix", function () {
  it("enforces provider/acl/router/state-manager permissions and dynamic ACL binding", async function () {
    const [owner, proposer, routerAdmin, , outsider] = await ethers.getSigners();

    const {
      provider,
      acl,
      stateManager: sm,
      router,
      bridge,
      erc20Gateway,
      ethGateway,
      verifier,
    } = await deployCoreSystem(owner.address, proposer.address);

    // 1) Provider ownership gate
    await expect(
      provider.connect(outsider).setAddress(await provider.BRIDGE_ID(), outsider.address)
    ).to.be.reverted;

    // 2) ACL admin gate (OZ AccessControl)
    await expect(
      acl.connect(outsider).grantRole(await acl.ROUTER_ADMIN_ROLE(), routerAdmin.address)
    ).to.be.reverted;

    // 3) Router admin role controls mapping writes
    await acl.connect(owner).grantRole(await acl.ROUTER_ADMIN_ROLE(), routerAdmin.address);
    const token = ethers.Wallet.createRandom().address;
    const tokenId = ethers.utils.hexZeroPad("0x01", 32);

    await expect(router.connect(outsider).setTokenMapping(token, tokenId)).to.be.revertedWithCustomError(router, "OnlyRouterAdmin");
    await expect(router.connect(routerAdmin).setTokenMapping(token, tokenId)).to.not.be.reverted;

    const window = await buildBridgeWindow(sm, bridge);
    await expect(sm.connect(outsider).applyBridgeWindow(...window))
      .to.be.revertedWithCustomError(sm, "OnlyProposer");
    await sm.connect(proposer).applyBridgeWindow(...window);
    expect(await sm.lastFinalizedCheckpointId()).to.equal(1);

    // 6) Dynamic ACL binding via provider: swap ACL manager and permissions change immediately
    const newAcl = await deployProxy("PsyACLManager", [
      owner.address,
      owner.address,
      owner.address,
      owner.address,
      proposer.address,
    ]);
    await provider.connect(owner).setAddress(await provider.ACL_MANAGER_ID(), newAcl.address);

    // routerAdmin role existed only on old acl, should now fail
    await expect(router.connect(routerAdmin).setTokenMapping(token, ethers.utils.hexZeroPad("0x02", 32)))
      .to.be.revertedWithCustomError(router, "OnlyRouterAdmin");

    // grant role on new ACL, now it works again
    await newAcl.connect(owner).grantRole(await newAcl.ROUTER_ADMIN_ROLE(), routerAdmin.address);
    await expect(router.connect(routerAdmin).setTokenMapping(token, ethers.utils.hexZeroPad("0x03", 32))).to.not.be.reverted;

    // 7) Wiring sanity: critical addresses are non-zero
    expect(await provider["getAddress(bytes32)"](await provider.ACL_MANAGER_ID())).to.equal(newAcl.address);
    expect(await provider["getAddress(bytes32)"](await provider.BRIDGE_ID())).to.equal(bridge.address);
    expect(await provider["getAddress(bytes32)"](await provider.ROUTER_ID())).to.equal(router.address);
    expect(await provider["getAddress(bytes32)"](await provider.STATE_MANAGER_ID())).to.equal(sm.address);
    expect(await provider["getAddress(bytes32)"](await provider.ERC20_GATEWAY_ID())).to.equal(erc20Gateway.address);
    expect(await provider["getAddress(bytes32)"](await provider.ETH_GATEWAY_ID())).to.equal(ethGateway.address);
    expect(await provider["getAddress(bytes32)"](await provider.ZK_VERIFIER_ID())).to.equal(verifier.address);
  });
});
