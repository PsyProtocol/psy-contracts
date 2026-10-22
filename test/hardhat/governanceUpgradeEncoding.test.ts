import { expect } from "chai";
import { artifacts, ethers } from "hardhat";
import fs from "fs";
import os from "os";
import path from "path";
const { encodeGovernanceUpgrade } = require("../../scripts/upgrade/encode-governance-upgrade.cjs");

describe("existing-testnet governance atomic upgrade encoding", function () {
  it("encodes ACL upgrade and nonempty atomic Bridge initialization for all three testnets", async function () {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "psy-governance-encoding-"));
    try {
      const targets: Record<number,string> = {11155111:"0x9809D527544054bbb7357FB5b9e484590A72f2DF",97:"0xaf1c879A6052701bEA56373bcF6F9fB4568C7c70",84532:"0x7740B9be2886751D9bB8E12c4548F33F20caFc70"};
      const config = {minDepositAmount:"1000000",depositCapacity:"40000000000",depositRefillPerSecond:"1666666666",custodyCap:"1000000000000000000000000",smallWithdrawalMax:"10",mediumWithdrawalMax:"100",smallWithdrawalDelay:"0",mediumWithdrawalDelay:"0",largeWithdrawalDelay:"0",configured:true};
      const token = "0x0000000000000000000000000000000000001001";
      const policy = path.join(dir, "policy.json");
      fs.writeFileSync(policy, JSON.stringify({chains:Object.entries(targets).map(([id,bridge])=>({chainId:Number(id),bridge,proxyAdmin:"0x0000000000000000000000000000000000001002",oldImplementation:"0x0000000000000000000000000000000000001003",contracts:{PsyACLManager:"0x0000000000000000000000000000000000001004",USDTToken:token},tokens:[ethers.constants.AddressZero,token,"0x0000000000000000000000000000000000001005"],configs:[config,config,config]}))}));
      const bridgeArtifact = path.join(dir, "bridge.json");
      const aclArtifact = path.join(dir, "acl.json");
      const artifact = await artifacts.readArtifact("Bridge");
      fs.writeFileSync(bridgeArtifact, JSON.stringify(artifact));
      fs.writeFileSync(aclArtifact, JSON.stringify(await artifacts.readArtifact("PsyACLManager")));
      const iface = new ethers.utils.Interface(artifact.abi);
      const admin = new ethers.utils.Interface(["function upgrade(address,address)","function upgradeAndCall(address,address,bytes)"]);
      const input = {policy,bridgeArtifact,aclArtifact,bridgeImplementation:"0x0000000000000000000000000000000000002001",aclImplementation:"0x0000000000000000000000000000000000002002"};
      for (const chainId of [11155111,97,84532]) {
        const encoded = encodeGovernanceUpgrade({...input,chainId});
        expect(encoded.offline_only).to.equal(true);
        expect(encoded.simulation_only).to.equal(false);
        const acl = admin.decodeFunctionData("upgrade",encoded.aclUpgrade.data);
        expect(acl[1]).to.equal(input.aclImplementation);
        const bridge = admin.decodeFunctionData("upgradeAndCall",encoded.bridgeUpgrade.data);
        expect(bridge[0]).to.equal(ethers.utils.getAddress(targets[chainId]));
        const init = iface.decodeFunctionData("initializeFlowLimits",bridge[2]);
        expect(init.configs[1].minDepositAmount).to.equal(1000000);
        expect(init.configs[1].depositCapacity).to.equal("40000000000");
        expect(init.configs[1].depositRefillPerSecond).to.equal(1666666666);
      }
      expect(()=>encodeGovernanceUpgrade({...input,chainId:1})).to.throw("Unsupported");
      expect(()=>encodeGovernanceUpgrade({...input,chainId:97,bridgeImplementation:targets[97]})).to.throw("existing target");
      expect(()=>encodeGovernanceUpgrade({...input,chainId:97,bridgeImplementation:ethers.constants.AddressZero})).to.throw("Zero");
      expect(()=>encodeGovernanceUpgrade({...input,chainId:97,bridgeImplementation:"0x0000000000000000000000000000000000002020"})).to.throw("Simulation");
    } finally { fs.rmSync(dir,{recursive:true,force:true}); }
  });
});
