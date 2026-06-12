import { promises as fsp } from "fs";
import path from "path";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

// ── Verification metadata per contract ──────────────────────────
export type ContractVerificationMeta = {
  address: string;
  constructorArgs: unknown[];
  libraries: Record<string, string> | undefined;
  /** Source name for FQN (e.g. "contracts/StateManager.sol") */
  sourceName: string;
  /** Contract name (e.g. "StateManager") */
  contractName: string;
  /** FQN override: use this instead of sourceName:contractName */
  fqnOverride?: string;
  /** true if this contract should be skipped during batch verify */
  skipVerify?: boolean;
};

export type VerificationRegistry = Record<string, ContractVerificationMeta>;

// ── Registry file path ──────────────────────────────────────────
function registryPath(hre: HardhatRuntimeEnvironment): string {
  return path.join(hre.config.paths.deployments!, hre.network.name, "verifiable.json");
}

/**
 * Read the current verification registry.
 */
export async function readRegistry(hre: HardhatRuntimeEnvironment): Promise<VerificationRegistry> {
  const file = registryPath(hre);
  try {
    const raw = await fsp.readFile(file, "utf8");
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/**
 * Register a contract for verification.
 * Called right after each successful deployment.
 */
export async function registerVerification(
  hre: HardhatRuntimeEnvironment,
  name: string,
  address: string,
  overrides: {
    constructorArgs?: unknown[];
    libraries?: Record<string, string>;
    sourceName?: string;
    contractName?: string;
    fqnOverride?: string;
    skipVerify?: boolean;
  },
): Promise<void> {
  let sourceName = overrides.sourceName ?? "";
  let contractName = overrides.contractName ?? name;

  if (!sourceName) {
    try {
      // Strip _Proxy / _Implementation suffix to find the main contract artifact
      const artifactName = name.replace(/_Proxy$/, "").replace(/_Implementation$/, "");
      const art = await hre.artifacts.readArtifact(artifactName);
      sourceName = art.sourceName;
      contractName = art.contractName;
    } catch {
      // External contract — caller must provide sourceName or fqnOverride
    }
  }

  const meta: ContractVerificationMeta = {
    address,
    constructorArgs: overrides.constructorArgs ?? [],
    libraries: overrides.libraries ?? undefined,
    sourceName,
    contractName,
    fqnOverride: overrides.fqnOverride,
    skipVerify: overrides.skipVerify ?? false,
  };

  const registry = await readRegistry(hre);
  registry[name] = meta;
  await writeRegistry(hre, registry);

  console.log(`  [verify] registered "${name}" → ${address}`);
}

/**
 * Write the verification registry.
 */
export async function writeRegistry(
  hre: HardhatRuntimeEnvironment,
  registry: VerificationRegistry,
): Promise<void> {
  const file = registryPath(hre);
  const dir = path.dirname(file);
  await fsp.mkdir(dir, { recursive: true });
  await fsp.writeFile(file, JSON.stringify(registry, null, 2) + "\n", "utf8");
}
