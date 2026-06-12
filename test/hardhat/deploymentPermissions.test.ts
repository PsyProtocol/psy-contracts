import { expect } from "chai";
import { deployments, ethers } from "hardhat";

describe("Deployed Permission Configuration", function () {
  it("matches expected permissions after running deploy scripts", async function () {
    await deployments.fixture(["transfer_ownership"]);

    const signers = await ethers.getSigners();
    const admin = signers[0];
    const proposer = signers[1];
    const outsider = signers[2];

    const provider = await ethers.getContractAt("PsyAddressesProvider", (await deployments.get("PsyAddressesProvider")).address);
    const acl = await ethers.getContractAt("PsyACLManager", (await deployments.get("PsyACLManager")).address);
    const sm = await ethers.getContractAt("StateManager", (await deployments.get("StateManager")).address);
    const bridge = await ethers.getContractAt("Bridge", (await deployments.get("Bridge")).address);
    const router = await ethers.getContractAt("Router", (await deployments.get("Router")).address);
    const erc20Gateway = await ethers.getContractAt("ERC20Gateway", (await deployments.get("ERC20Gateway")).address);
    const ethGateway = await ethers.getContractAt("ETHGateway", (await deployments.get("ETHGateway")).address);
    const verifier = await ethers.getContractAt(
      "src/GnarkGroth16Verifier.sol:Verifier",
      (await deployments.get("ZKVerifier")).address
    );

    // 1) Provider wiring after deployment
    expect(await provider["getAddress(bytes32)"](await provider.ACL_MANAGER_ID())).to.equal(acl.address);
    expect(await provider["getAddress(bytes32)"](await provider.BRIDGE_ID())).to.equal(bridge.address);
    expect(await provider["getAddress(bytes32)"](await provider.STATE_MANAGER_ID())).to.equal(sm.address);
    expect(await provider["getAddress(bytes32)"](await provider.ROUTER_ID())).to.equal(router.address);
    expect(await provider["getAddress(bytes32)"](await provider.ERC20_GATEWAY_ID())).to.equal(erc20Gateway.address);
    expect(await provider["getAddress(bytes32)"](await provider.ETH_GATEWAY_ID())).to.equal(ethGateway.address);
    expect(await provider["getAddress(bytes32)"](await provider.ZK_VERIFIER_ID())).to.equal(await verifier.getAddress());

    // 2) ACL roles assigned by deployment config
    expect(await acl.hasRole(await acl.BRIDGE_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await acl.hasRole(await acl.ROUTER_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await acl.hasRole(await acl.STATE_MANAGER_ADMIN_ROLE(), admin.address)).to.equal(true);
    expect(await acl.hasRole(await acl.PROPOSER_ROLE(), proposer.address)).to.equal(true);

    // 3) Only owner can mutate provider address book
    await expect(
      provider.connect(outsider).setAddress(await provider.BRIDGE_ID(), outsider.address)
    ).to.be.reverted;

    // 4) Router admin gate works
    await expect(
      router.connect(outsider).setTokenMapping(ethers.Wallet.createRandom().address, ethers.utils.hexZeroPad("0x01", 32))
    ).to.be.revertedWithCustomError(router, "OnlyRouterAdmin");

    await expect(
      router.connect(admin).setTokenMapping(ethers.Wallet.createRandom().address, ethers.utils.hexZeroPad("0x02", 32))
    ).to.not.be.reverted;

    // 5) Proposer gate on finalize works
    await expect(
      sm.connect(outsider).finalize(
        "0x",
        ethers.constants.HashZero,
        [ethers.constants.HashZero, ethers.constants.HashZero],
        ethers.constants.HashZero,
        0,
        1,
        new Array(9).fill(ethers.constants.HashZero),
        new Array(9).fill(ethers.constants.HashZero)
      )
    ).to.be.revertedWithCustomError(sm, "OnlyProposer");

    await expect(
      sm.connect(proposer).finalize(
        "0x",
        ethers.constants.HashZero,
        [ethers.constants.HashZero, ethers.constants.HashZero],
        ethers.constants.HashZero,
        0,
        1,
        new Array(9).fill(ethers.constants.HashZero),
        new Array(9).fill(ethers.constants.HashZero)
      )
    ).to.be.revertedWithCustomError(sm, "InvalidProof");
  });
});
