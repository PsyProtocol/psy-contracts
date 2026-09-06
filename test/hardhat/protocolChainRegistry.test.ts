import { expect } from "chai";
import {
  protocolConfig,
  resolveProtocolNetworkName,
  validateProtocolChainRegistry,
} from "../../protocol-config";

describe("protocol chain registry", function () {
  it("assigns one bridge index per logical chain", function () {
    expect(protocolConfig.chains.localhost.l1ChainIndex).to.equal(0);
    expect(protocolConfig.chains.localhostBsc.l1ChainIndex).to.equal(1);
    expect(protocolConfig.chains.localhostBase.l1ChainIndex).to.equal(2);
    expect(protocolConfig.chains.sepolia.l1ChainIndex).to.equal(0);
    expect(protocolConfig.chains.bscTestnet.l1ChainIndex).to.equal(1);
    expect(protocolConfig.chains.baseSepolia.l1ChainIndex).to.equal(2);
    expect(protocolConfig.chains.ethereum.l1ChainIndex).to.equal(0);
    expect(protocolConfig.chains.bsc.l1ChainIndex).to.equal(1);
    expect(protocolConfig.chains.base.l1ChainIndex).to.equal(2);
    expect(() => validateProtocolChainRegistry()).not.to.throw();
  });

  it("activates and resolves the three test networks", function () {
    expect(protocolConfig.activeNetworks).to.deep.equal(["sepolia", "bscTestnet", "baseSepolia"]);
    expect(resolveProtocolNetworkName("sepolia")).to.equal("sepolia");
    expect(resolveProtocolNetworkName("bscTestnet")).to.equal("bscTestnet");
    expect(resolveProtocolNetworkName("baseSepolia")).to.equal("baseSepolia");
    expect(resolveProtocolNetworkName("bsc")).to.equal("bsc");
    expect(resolveProtocolNetworkName("base")).to.equal("base");
  });

  it("defines three distinct localhost EVM chains", function () {
    expect(protocolConfig.chains.localhost.l1ChainId).to.equal(31337);
    expect(protocolConfig.chains.localhostBsc.l1ChainId).to.equal(31338);
    expect(protocolConfig.chains.localhostBase.l1ChainId).to.equal(31339);
    expect(resolveProtocolNetworkName("localhostBsc")).to.equal("localhostBsc");
    expect(resolveProtocolNetworkName("localhostBase")).to.equal("localhostBase");
  });

  it("rejects an index collision between different logical chains", function () {
    const invalid = structuredClone(protocolConfig);
    invalid.chains.base.l1ChainIndex = invalid.chains.bsc.l1ChainIndex;
    expect(() => validateProtocolChainRegistry(invalid)).to.throw("Duplicate l1ChainIndex 1");
  });
});
