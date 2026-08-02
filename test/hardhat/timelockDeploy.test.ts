import { expect } from "chai";
import hre, { deployments, ethers } from "hardhat";
import grantTimelockRoles from "../../deploy/007d_grant_timelock_roles";
import transferProxyAdminToTimelock from "../../deploy/007e_transfer_proxy_admin_to_timelock";
import { ensureHardhatDeploymentChainId } from "./helpers/deploySystem";

describe("timelock deployment defaults", function () {
  it("deploys timelock without granting admin roles", async function () {
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["timelock_roles"]);
    const timelock = await deployments.get("ExecutorWithTimelock");
    const aclDeployment = await deployments.get("PsyACLManager");
    const acl = await ethers.getContractAt(aclDeployment.abi, aclDeployment.address);
    const bridgeRole = await acl.BRIDGE_ADMIN_ROLE();
    const stateRole = await acl.STATE_MANAGER_ADMIN_ROLE();

    expect(await acl.hasRole(bridgeRole, timelock.address)).to.equal(false);
    expect(await acl.hasRole(stateRole, timelock.address)).to.equal(false);
  });

  it("can opt into timelock role grants and proxy-admin ownership transfer", async function () {
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["timelock"]);
    process.env.GRANT_TIMELOCK_ROLES = "1";
    process.env.TRANSFER_PROXY_ADMIN_TO_TIMELOCK = "1";
    try {
      await grantTimelockRoles(hre);
      await transferProxyAdminToTimelock(hre);
      const timelock = await deployments.get("ExecutorWithTimelock");
      const aclDeployment = await deployments.get("PsyACLManager");
      const acl = await ethers.getContractAt(aclDeployment.abi, aclDeployment.address);
      const proxyAdminDeployment = await deployments.get("DefaultProxyAdmin");
      const proxyAdmin = await ethers.getContractAt(proxyAdminDeployment.abi, proxyAdminDeployment.address);
      const bridgeRole = await acl.BRIDGE_ADMIN_ROLE();
      const stateRole = await acl.STATE_MANAGER_ADMIN_ROLE();

      expect(await acl.hasRole(bridgeRole, timelock.address)).to.equal(true);
      expect(await acl.hasRole(stateRole, timelock.address)).to.equal(true);
      expect(await proxyAdmin.owner()).to.equal(timelock.address);
    } finally {
      delete process.env.GRANT_TIMELOCK_ROLES;
      delete process.env.TRANSFER_PROXY_ADMIN_TO_TIMELOCK;
    }
  });
});
