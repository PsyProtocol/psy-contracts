import path from "path";
import { expect } from "chai";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { networkConfig } from "../../helper-hardhat-config";
import { loadDeployConfig } from "../../deploy/deploy-config";
import { bridgeProxyDeploymentBlock } from "../../deploy/008_export_deployed_contracts";
import { protocolConfig } from "../../protocol-config";

const DEPLOYER = "0x1000000000000000000000000000000000000001";

function fakeHre(networkName: string, connectedChainId: number): HardhatRuntimeEnvironment {
  return {
    network: { name: networkName },
    config: { paths: { root: path.resolve(__dirname, "../..") } },
    getChainId: async () => String(connectedChainId),
    getNamedAccounts: async () => ({
      deployer: DEPLOYER,
      admin: DEPLOYER,
      proposer: DEPLOYER,
    }),
  } as unknown as HardhatRuntimeEnvironment;
}

describe("multi-chain deployment networks", function () {
  it("maps local and public test networks to their protocol identities", function () {
    for (const key of [
      "localhost",
      "localhostBsc",
      "localhostBase",
      "sepolia",
      "bscTestnet",
      "baseSepolia",
    ] as const) {
      expect(networkConfig[key].chainId).to.equal(protocolConfig.chains[key].l1ChainId);
      expect(networkConfig[key].rpcUrl).to.equal(protocolConfig.chains[key].defaultRpcUrl);
    }
  });

  it("uses the registry chain index when a network has no config file", async function () {
    const cfg = await loadDeployConfig(
      fakeHre("bscTestnet", protocolConfig.chains.bscTestnet.l1ChainId),
    );
    expect(cfg.l1ChainIndex).to.equal(1);
  });

  it("refuses an RPC whose chain id does not match the selected network", async function () {
    await expect(loadDeployConfig(fakeHre("baseSepolia", 31337))).to.be.rejectedWith(
      "RPC eth_chainId=31337 does not match protocol-config l1ChainId=84532",
    );
  });
});

describe("Bridge_Proxy deployment block export", function () {
  it("uses the original proxy receipt block, not an upgrade execute block", function () {
    expect(bridgeProxyDeploymentBlock({ receipt: { blockNumber: 54 } })).to.equal(54);
  });

  for (const [label, deployment] of [
    ["missing proxy", undefined],
    ["missing receipt", {}],
    ["zero", { receipt: { blockNumber: 0 } }],
    ["fractional", { receipt: { blockNumber: 1.5 } }],
    ["unsafe", { receipt: { blockNumber: Number.MAX_SAFE_INTEGER + 1 } }],
  ] as const) {
    it(`refuses a ${label} Bridge_Proxy receipt`, function () {
      expect(() => bridgeProxyDeploymentBlock(deployment)).to.throw(/positive safe-integer blockNumber/);
    });
  }
});
