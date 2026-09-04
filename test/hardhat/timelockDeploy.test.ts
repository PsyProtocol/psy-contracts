import { expect } from "chai";
import hre, { deployments, ethers } from "hardhat";
import grantTimelockRoles from "../../deploy/007d_grant_timelock_roles";
import transferProxyAdminToTimelock from "../../deploy/007e_transfer_proxy_admin_to_timelock";
import transferProtocolOwnership from "../../deploy/007_transfer_ownership";
import deployTokenFaucet from "../../deploy/007b_deploy_token_faucet";
import { ensureHardhatDeploymentChainId } from "./helpers/deploySystem";

describe("timelock deployment defaults", function () {
  it("deploys timelock without granting admin roles", async function () {
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["timelock_roles"]);
    const timelock = await deployments.get("ExecutorWithTimelock");
    const aclDeployment = await deployments.get("PsyACLManager");
    const acl = await ethers.getContractAt(aclDeployment.abi, aclDeployment.address);
    const defaultAdminRole = await acl.DEFAULT_ADMIN_ROLE();
    const bridgeRole = await acl.BRIDGE_ADMIN_ROLE();
    const routerRole = await acl.ROUTER_ADMIN_ROLE();
    const stateRole = await acl.STATE_MANAGER_ADMIN_ROLE();
    const guardianRole = await acl.GUARDIAN_ROLE();
    const timelockContract = await ethers.getContractAt(timelock.abi, timelock.address);
    const governanceSafe = await timelockContract.getAdmin();

    expect(await acl.hasRole(defaultAdminRole, timelock.address)).to.equal(false);
    expect(await acl.hasRole(bridgeRole, timelock.address)).to.equal(false);
    expect(await acl.hasRole(routerRole, timelock.address)).to.equal(false);
    expect(await acl.hasRole(stateRole, timelock.address)).to.equal(false);
    expect(await acl.hasRole(guardianRole, governanceSafe)).to.equal(false);
  });

  it("can opt into timelock role grants and proxy-admin ownership transfer", async function () {
    await ensureHardhatDeploymentChainId();
    await deployments.fixture(["transfer_ownership"]);
    process.env.GRANT_TIMELOCK_ROLES = "1";
    process.env.REVOKE_REPLACED_ADMIN_ROLES = "1";
    process.env.TRANSFER_PROTOCOL_OWNERSHIP_TO_TIMELOCK = "1";
    process.env.TRANSFER_PROXY_ADMIN_TO_TIMELOCK = "1";
    try {
      await grantTimelockRoles(hre);
      await transferProtocolOwnership(hre);
      await deployTokenFaucet(hre);
      await transferProxyAdminToTimelock(hre);
      const timelock = await deployments.get("ExecutorWithTimelock");
      const aclDeployment = await deployments.get("PsyACLManager");
      const acl = await ethers.getContractAt(aclDeployment.abi, aclDeployment.address);
      const proxyAdminDeployment = await deployments.get("DefaultProxyAdmin");
      const proxyAdmin = await ethers.getContractAt(proxyAdminDeployment.abi, proxyAdminDeployment.address);
      const defaultAdminRole = await acl.DEFAULT_ADMIN_ROLE();
      const bridgeRole = await acl.BRIDGE_ADMIN_ROLE();
      const routerRole = await acl.ROUTER_ADMIN_ROLE();
      const stateRole = await acl.STATE_MANAGER_ADMIN_ROLE();
      const guardianRole = await acl.GUARDIAN_ROLE();
      const timelockContract = await ethers.getContractAt(timelock.abi, timelock.address);
      const governanceSafe = await timelockContract.getAdmin();
      const [replacedAdmin] = await ethers.getSigners();

      expect(await acl.hasRole(defaultAdminRole, timelock.address)).to.equal(true);
      expect(await acl.hasRole(bridgeRole, timelock.address)).to.equal(true);
      expect(await acl.hasRole(routerRole, timelock.address)).to.equal(true);
      expect(await acl.hasRole(stateRole, timelock.address)).to.equal(true);
      expect(await acl.hasRole(guardianRole, governanceSafe)).to.equal(true);
      expect(await acl.hasRole(defaultAdminRole, replacedAdmin.address)).to.equal(false);
      expect(await acl.hasRole(bridgeRole, replacedAdmin.address)).to.equal(false);
      expect(await acl.hasRole(routerRole, replacedAdmin.address)).to.equal(false);
      expect(await acl.hasRole(stateRole, replacedAdmin.address)).to.equal(false);
      expect(await acl.owner()).to.equal(timelock.address);
      const bridgeDeployment = await deployments.get("Bridge");
      const bridge = await ethers.getContractAt(bridgeDeployment.abi, bridgeDeployment.address);
      const faucetDeployment = await deployments.get("TokenFaucetManager");
      const faucet = await ethers.getContractAt(faucetDeployment.abi, faucetDeployment.address);
      expect(await bridge.owner()).to.equal(timelock.address);
      expect(await faucet.owner()).to.equal(timelock.address);
      expect(await proxyAdmin.owner()).to.equal(timelock.address);
    } finally {
      delete process.env.GRANT_TIMELOCK_ROLES;
      delete process.env.REVOKE_REPLACED_ADMIN_ROLES;
      delete process.env.TRANSFER_PROTOCOL_OWNERSHIP_TO_TIMELOCK;
      delete process.env.TRANSFER_PROXY_ADMIN_TO_TIMELOCK;
    }
  });
});
