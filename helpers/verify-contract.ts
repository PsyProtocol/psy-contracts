/**
 * Verify contracts on Etherscan.
 * Supports Hardhat (verify:verify) and Foundry (forge verify-contract).
 *
 * Two entry points:
 *   1. verifyDeployments(hre)        – reads from hardhat-deploy's deployment files (recommended)
 *   2. verifyFromRegistry(hre)       – reads from verifiable.json (opt-in wrapper)
 *
 * Mirrors paraspace-core's verifyContract() pattern.
 */
import { promises as fsp } from "fs";
import path from "path";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { HttpNetworkConfig } from "hardhat/types";
import {
  ETHERSCAN_VERIFICATION_PROVIDER,
  ETHERSCAN_VERIFICATION_MAX_RETRIES,
  ETHERSCAN_APIS,
} from "./hardhat-constants";
import { forgeVerifyContract } from "./foundry";

// ── Types ───────────────────────────────────────────────────────

export type VerifyOptions = {
  constructorArgs?: unknown[];
  libraries?: Record<string, string>;
  fqnOverride?: string;
  abiOverride?: any[];
  compilerVersion?: string;
  optimizerRuns?: number;
  evmVersion?: string;
  viaIR?: boolean;
};

type ContractMeta = {
  name: string;
  address: string;
  constructorArgs: unknown[];
  libraries: Record<string, string> | undefined;
  fqnOverride?: string;
  abiOverride?: any[];
  compilerVersion?: string;
  optimizerRuns?: number;
  evmVersion?: string;
  viaIR?: boolean;
};

async function resolveFoundryLibraries(
  hre: HardhatRuntimeEnvironment,
  libraries?: Record<string, string>,
): Promise<Record<string, string> | undefined> {
  if (!libraries || Object.keys(libraries).length === 0) return undefined;

  const entries = await Promise.all(
    Object.entries(libraries).map(async ([libName, libAddress]) => {
      try {
        const art = await hre.artifacts.readArtifact(libName);
        return [`${art.sourceName}:${art.contractName}`, libAddress] as const;
      } catch {
        return [libName, libAddress] as const;
      }
    }),
  );

  return Object.fromEntries(entries);
}

// ── Resolve FQN & ABI from Hardhat artifacts ────────────────────

async function resolveArtifact(
  hre: HardhatRuntimeEnvironment,
  deployName: string,
): Promise<{ sourceName: string; contractName: string; abi: any[] } | null> {
  try {
    const artName = deployName.replace(/_Proxy$/, "").replace(/_Implementation$/, "");
    const art = await hre.artifacts.readArtifact(artName);
    if (art.sourceName) {
      return { sourceName: art.sourceName, contractName: art.contractName, abi: art.abi };
    }
  } catch {
    // artifact not found — skip
  }
  return null;
}

// ── Verify a single contract ────────────────────────────────────

export async function verifyContract(
  hre: HardhatRuntimeEnvironment,
  name: string,
  address: string,
  opts: VerifyOptions = {},
): Promise<void> {
  const provider = ETHERSCAN_VERIFICATION_PROVIDER;
  let sourceName = "";
  let contractName = name;
  let abi: any[] = [];

  if (opts.fqnOverride) {
    const parts = opts.fqnOverride.split(":");
    sourceName = parts[0];
    contractName = parts[1] ?? name;
    abi = opts.abiOverride ?? [];
  } else {
    const art = await resolveArtifact(hre, name);
    if (art) {
      sourceName = art.sourceName;
      contractName = art.contractName;
      abi = art.abi;
    }
  }

  const contractFQN = opts.fqnOverride ?? (sourceName ? `${sourceName}:${contractName}` : name);

  console.log(`\n[VERIFY] ${name}`);
  console.log(`  address: ${address}`);

  if (provider === "foundry") {
    const chainId = (hre.network.config as HttpNetworkConfig).chainId ?? 0;
    const rpcUrl = (hre.network.config as HttpNetworkConfig).url ?? "";
    const verifierUrl = ETHERSCAN_APIS[hre.network.name];
    const artifact = sourceName ? { sourceName, contractName, abi } : undefined;

    console.log(`  method:  forge`);

    await forgeVerifyContract(
      name,
      address,
      artifact as any,
      chainId,
      rpcUrl,
      opts.constructorArgs ?? [],
      await resolveFoundryLibraries(hre, opts.libraries),
      verifierUrl,
      {
        compilerVersion: opts.compilerVersion,
        optimizerRuns: opts.optimizerRuns,
        evmVersion: opts.evmVersion,
        viaIR: opts.viaIR,
      },
    );
  } else {
    console.log(`  method:  hardhat`);

    await hardhatVerify(hre, name, address, contractFQN, opts);
  }
}

// ── Hardhat verify:verify with retry ────────────────────────────

const FATAL_ERRORS = [
  "The address provided as argument contains a contract, but its bytecode",
  "Daily limit of 100 source code submissions reached",
  "has no bytecode",
  "The constructor for",
];
const OK_ERRORS = ["Already Verified", "Contract source code already verified"];

async function hardhatVerify(
  hre: HardhatRuntimeEnvironment,
  name: string,
  address: string,
  contractFQN: string,
  opts: VerifyOptions,
): Promise<void> {
  const params: Record<string, any> = {
    address,
    constructorArguments: opts.constructorArgs ?? [],
  };
  if (contractFQN && !contractFQN.startsWith(":")) {
    params.contract = contractFQN;
  }
  if (opts.libraries && Object.keys(opts.libraries).length > 0) {
    params.libraries = opts.libraries;
  }

  let lastError: Error | undefined;

  for (let attempt = ETHERSCAN_VERIFICATION_MAX_RETRIES; attempt >= 0; attempt--) {
    await new Promise((r) => setTimeout(r, attempt > 0 ? 3000 : 1000));

    try {
      await hre.run("verify:verify", params);
      console.log(`  ✅ ${name} verified`);
      return;
    } catch (error: any) {
      const errMsg = error?.message || String(error) || "";

      if (OK_ERRORS.some((e) => errMsg.includes(e))) {
        console.log(`  ℹ️  Already verified`);
        return;
      }
      if (FATAL_ERRORS.some((e) => errMsg.includes(e))) {
        console.error(`  ❌ Fatal: ${errMsg.substring(0, 300)}`);
        throw error;
      }

      lastError = error;
      if (attempt > 0) {
        console.warn(`  ⚠️  Retry (${attempt} left): ${errMsg.substring(0, 200)}`);
      }
    }
  }

  console.error(`  ❌ ${name} FAILED: ${lastError?.message ?? "unknown error"}`);
}

function fqnFromDeploymentMetadata(data: { metadata?: string }): string | undefined {
  if (!data.metadata) return undefined;
  try {
    const metadata = JSON.parse(data.metadata) as {
      settings?: { compilationTarget?: Record<string, string> };
    };
    const target = metadata.settings?.compilationTarget;
    if (!target) return undefined;
    const [[sourceName, contractName]] = Object.entries(target);
    if (!sourceName || !contractName) return undefined;
    const localSourceName = sourceName.startsWith("solc_0.8/")
      ? `node_modules/hardhat-deploy/${sourceName}`
      : sourceName;
    return `${localSourceName}:${contractName}`;
  } catch {
    return undefined;
  }
}


function compilerSettingsFromDeploymentMetadata(data: { metadata?: string }): {
  compilerVersion?: string;
  optimizerRuns?: number;
  evmVersion?: string;
  viaIR?: boolean;
} {
  if (!data.metadata) return {};
  try {
    const metadata = JSON.parse(data.metadata) as {
      compiler?: { version?: string };
      settings?: {
        optimizer?: { runs?: number };
        evmVersion?: string;
        viaIR?: boolean;
      };
    };
    return {
      compilerVersion: metadata.compiler?.version,
      optimizerRuns: metadata.settings?.optimizer?.runs,
      evmVersion: metadata.settings?.evmVersion,
      viaIR: metadata.settings?.viaIR,
    };
  } catch {
    return {};
  }
}
function abiFromDeploymentMetadata(data: { metadata?: string }): any[] | undefined {
  if (!data.metadata) return undefined;
  try {
    const metadata = JSON.parse(data.metadata) as {
      output?: { abi?: any[] };
    };
    return metadata.output?.abi;
  } catch {
    return undefined;
  }
}

// ── Entry point 1: read all from hardhat-deploy files ───────────

/**
 * Scan `deployments/<network>/` for all deployment JSON files and verify each.
 * Skips Proxy contracts (standard OpenZeppelin bytecode, auto-detected by Etherscan),
 * deployed-contracts.json, and verifiable.json.
 */
export async function verifyDeployments(hre: HardhatRuntimeEnvironment): Promise<void> {
  const network = hre.network.name;
  const deployDir = path.join(hre.config.paths.deployments!, network);

  let files: string[];
  try {
    files = await fsp.readdir(deployDir);
  } catch {
    console.error(`No deployments directory for "${network}"`);
    return;
  }

  const fileSet = new Set(files);
  const contracts = (await Promise.all(
    files
      .filter((f) => f.endsWith(".json") && !["deployed-contracts.json", "verifiable.json"].includes(f))
      .map(async (f) => {
        const name = f.replace(/\.json$/, "");
        // Skip hardhat-deploy infrastructure; proxies are standard OpenZeppelin bytecode.
        if (name.startsWith("DefaultProxyAdmin")) return null;
        // Skip proxy contracts — standard bytecode, auto-detected by Etherscan
        if (name.endsWith("_Proxy")) return null;
        // Skip proxy main entries: if Name_Implementation.json exists, Name.json is the proxy address
        if (!name.endsWith("_Implementation") && fileSet.has(`${name}_Implementation.json`)) return null;

        try {
          const raw = await fsp.readFile(path.join(deployDir, f), "utf8");
          const data = JSON.parse(raw);
          if (!data.address || data.address === "0x0000000000000000000000000000000000000000") return null;
          const compilerSettings = compilerSettingsFromDeploymentMetadata(data);
          const meta: ContractMeta = {
            name,
            address: data.address,
            constructorArgs: data.args ?? [],
            libraries: data.libraries ?? undefined,
            fqnOverride: fqnFromDeploymentMetadata(data),
            abiOverride: abiFromDeploymentMetadata(data),
            ...compilerSettings,
          };
          return meta;
        } catch {
          return null;
        }
      }),
  )).filter((c): c is ContractMeta => c !== null);

  if (contracts.length === 0) {
    console.log("No deployable contracts found.");
    return;
  }

  const networkName = hre.network.name;
  console.log(`\n========================================`);
  console.log(`  Contract Verification`);
  console.log(`  Provider: ${ETHERSCAN_VERIFICATION_PROVIDER}`);
  console.log(`  Network:  ${networkName}`);
  console.log(`  Found:    ${contracts.length} contracts (+ ${files.filter(f => f.endsWith("_Proxy.json")).length} proxy artifacts skipped)`);
  console.log(`========================================\n`);

  const failures: string[] = [];

  for (const c of contracts.sort((a, b) => a.name.localeCompare(b.name))) {
    try {
      await verifyContract(hre, c.name, c.address, {
        constructorArgs: c.constructorArgs,
        libraries: c.libraries,
        fqnOverride: c.fqnOverride,
        abiOverride: c.abiOverride,
        compilerVersion: c.compilerVersion,
        optimizerRuns: c.optimizerRuns,
        evmVersion: c.evmVersion,
        viaIR: c.viaIR,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      failures.push(`${c.name}: ${message}`);
      console.error(`  ❌ ${c.name}: ${message}`);
    }
  }

  if (failures.length > 0) {
    throw new Error(`Verification failed for ${failures.length} contract(s): ${failures.join("; ")}`);
  }

  console.log(`\n========================================`);
  console.log(`  Verification complete`);
  console.log(`========================================\n`);
}

// ── Entry point 2: read from opt-in verifiable.json registry ────

/**
 * Verify contracts from the registry (generated by deploy-helper's unified deploy()).
 */
export async function verifyFromRegistry(hre: HardhatRuntimeEnvironment): Promise<void> {
  const { readRegistry } = await import("./verify-registry");
  const registry = await readRegistry(hre);
  const entries = Object.entries(registry).filter(([, m]) => !m.skipVerify);

  if (entries.length === 0) {
    console.log("No contracts in registry.");
    return;
  }

  console.log(`\n========================================`);
  console.log(`  Registry Contract Verification`);
  console.log(`  Provider: ${ETHERSCAN_VERIFICATION_PROVIDER}`);
  console.log(`  Network:  ${hre.network.name}`);
  console.log(`  Found:    ${entries.length} contracts`);
  console.log(`========================================\n`);

  const failures: string[] = [];

  for (const [name, meta] of entries.sort(([a], [b]) => a.localeCompare(b))) {
    try {
      await verifyContract(hre, name, meta.address, {
        constructorArgs: meta.constructorArgs,
        libraries: meta.libraries,
        fqnOverride: meta.fqnOverride,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      failures.push(`${name}: ${message}`);
      console.error(`  ❌ ${name}: ${message}`);
    }
  }

  if (failures.length > 0) {
    throw new Error(`Registry verification failed for ${failures.length} contract(s): ${failures.join("; ")}`);
  }

  console.log(`\n========================================`);
  console.log(`  Registry verification complete`);
  console.log(`========================================\n`);
}
