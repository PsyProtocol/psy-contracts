import { promises as fsp } from "fs";
import path from "path";
import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { protocolConfig, resolveProtocolNetworkName } from "../protocol-config";

type AddressMap = Record<string, string>;

function sortKeys<T extends Record<string, unknown>>(obj: T): T {
  return Object.fromEntries(
    Object.entries(obj).sort(([a], [b]) => a.localeCompare(b)),
  ) as T;
}

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, network } = hre;
  const { log } = deployments;
  const protocolNetwork = resolveProtocolNetworkName(network.name);
  const actualChainId = Number(await hre.getChainId());
  const exportedChainId = network.name === "localhost"
    ? protocolConfig.chains.localhost.l1ChainId
    : actualChainId;

  const all = await deployments.all();
  const allAddresses: AddressMap = {};
  const proxyAddresses: AddressMap = {};
  const implementationAddresses: AddressMap = {};
  const canonicalContracts: AddressMap = {};

  // ── Read verification metadata from verifiable.json ────────────
  let verificationMeta: Record<string, any> = {};
  try {
    const vPath = path.join(process.cwd(), "deployments", network.name, "verifiable.json");
    verificationMeta = JSON.parse(await fsp.readFile(vPath, "utf8"));
  } catch {
    // verifiable.json not found — not required
  }

  for (const [name, d] of Object.entries(all)) {
    allAddresses[name] = d.address;
    if (name.endsWith("_Proxy")) {
      proxyAddresses[name] = d.address;
      continue;
    }
    if (name.endsWith("_Implementation")) {
      implementationAddresses[name] = d.address;
      continue;
    }
    canonicalContracts[name] = d.address;
  }

  const coreNames = [
    "PsyAddressesProvider",
    "PsyACLManager",
    "DefaultProxyAdmin",
    "ZKVerifier",
    "WithdrawalClaimVerifier",
    "DepositBatchVerifier",
    "StateManager",
    "Bridge",
    "Router",
    "ERC20Gateway",
    "ETHGateway",
    "TokenFaucetManager",
    "PsyToken",
    "USDTToken",
    "WETH9",
    "Multicall3",
  ];
  const core: AddressMap = {};
  for (const name of coreNames) {
    if (allAddresses[name]) core[name] = allAddresses[name];
  }

  const resolvedTokens = Object.fromEntries(
    Object.entries(protocolConfig.tokens).flatMap(([symbol, token]) => {
      const deployment = token.deployments[protocolNetwork];
      if (!deployment) return [];
      const l1Address =
        deployment.l1Address ??
        (deployment.deployName && allAddresses[deployment.deployName] ? allAddresses[deployment.deployName] : undefined);
      if (!l1Address) return [];
      return [[symbol, {
        symbol: token.symbol,
        decimals: token.decimals,
        l2TokenContractId: token.l2TokenContractId,
        l1Address,
      }]];
    }),
  );

  const out = {
    network: network.name,
    chainId: String(exportedChainId),
    generatedAt: new Date().toISOString(),
    protocol: {
      chain: {
        ...protocolConfig.chains[protocolNetwork],
        l1ChainId: exportedChainId,
      },
      tokens: resolvedTokens,
    },
    core: sortKeys(core),
    contracts: sortKeys(canonicalContracts),
    proxies: sortKeys(proxyAddresses),
    implementations: sortKeys(implementationAddresses),
    /**
     * Verification metadata — populated automatically by deploy-helper.ts.
     * Each entry contains the info needed for Etherscan/Blockscout verification:
     *   address, constructorArgs, sourceName, contractName, libraries, fqnOverride
     */
    verify: sortKeys(verificationMeta),
  };

  const outputPath = path.join(process.cwd(), "deployments", network.name, "deployed-contracts.json");
  await fsp.mkdir(path.dirname(outputPath), { recursive: true });
  await fsp.writeFile(outputPath, JSON.stringify(out, null, 2) + "\n", "utf8");
  log(`wrote deployed contracts summary: ${outputPath}`);
};

export default func;
func.tags = ["export_deployed_contracts"];
func.dependencies = ["token_faucet"];
