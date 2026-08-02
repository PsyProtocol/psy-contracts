import { execFileSync } from "child_process";
import type { Artifact } from "hardhat/types";
import {
  ETHERSCAN_KEY,
  COMPILER_VERSION,
  COMPILER_OPTIMIZER_RUNS,
} from "./hardhat-constants";

export type LibraryAddresses = Record<string, string>;

export type CompilerSettings = {
  compilerVersion?: string;
  optimizerRuns?: number;
  evmVersion?: string;
  viaIR?: boolean;
};

/**
 * Build and execute a `forge verify-contract` command.
 *
 * Mirrors the pattern from paraspace-core.
 */
export async function forgeVerifyContract(
  contractId: string,
  address: string,
  artifact: { sourceName: string; contractName: string; abi: any[] } | undefined,
  chainId: number,
  rpcUrl: string,
  constructorArgs: unknown[],
  libraries?: LibraryAddresses,
  verifierUrl?: string,
  compilerSettings: CompilerSettings = {},
): Promise<void> {
  const etherscanApiKey = ETHERSCAN_KEY;
  if (!etherscanApiKey) {
    throw new Error("ETHERSCAN_KEY is required for Foundry verification");
  }

  if (!rpcUrl) {
    throw new Error(`RPC URL is required for Foundry verification on chain ${chainId}`);
  }

  const contractFQN = artifact
    ? `${artifact.sourceName}:${artifact.contractName}`
    : contractId;

  const compilerVersion = compilerSettings.compilerVersion ?? COMPILER_VERSION;
  const normalizedCompilerVersion = compilerVersion.includes("+")
    ? compilerVersion.slice(0, compilerVersion.indexOf("+"))
    : compilerVersion;
  const args = [
    "verify-contract",
    address,
    "--chain-id",
    String(chainId),
    "--num-of-optimizations",
    String(compilerSettings.optimizerRuns ?? COMPILER_OPTIMIZER_RUNS),
    "--watch",
    "--compiler-version",
    `v${normalizedCompilerVersion}`,
    "--evm-version",
    compilerSettings.evmVersion ?? "paris",
    "--verifier",
    "etherscan",
  ];
  if (compilerSettings.viaIR) {
    args.push("--via-ir");
  }
  args.push(contractFQN);
  if (verifierUrl && !verifierUrl.includes("etherscan.io")) {
    args.push("--verifier-url", verifierUrl);
  }

  // Constructor args via cast abi-encode
  if (constructorArgs.length > 0 && artifact) {
    const ctorAbi = (artifact.abi ?? []).find(
      (item: any) => item.type === "constructor",
    );
    if (ctorAbi && ctorAbi.inputs && ctorAbi.inputs.length > 0) {
      const argTypes = ctorAbi.inputs.map((x: any) => x.type).join(",");
      const argValues = constructorArgs.map((x) => (
        Array.isArray(x) ? `[${x.join(",")}]` : String(x)
      ));

      const encoded = execFileSync(
        "cast",
        ["abi-encode", `constructor(${argTypes})`, ...argValues],
        { encoding: "utf8" },
      ).trim();
      args.push("--constructor-args", encoded);
    }
  }

  // Libraries (forge format: --libraries sourceName:LibName:0x...)
  if (libraries && Object.keys(libraries).length > 0) {
    Object.entries(libraries).forEach(([libName, libAddress]) => {
      args.push("--libraries", `${libName}:${libAddress}`);
    });
  }

  console.log(`\n[VERIFY] ${contractId}`);
  console.log(`  address: ${address}`);
  console.log(`  FQN:     ${contractFQN}`);
  console.log(`  running: forge verify-contract ...`);

  try {
    execFileSync("forge", args, {
      stdio: "inherit",
      encoding: "utf8",
      env: {
        ...process.env,
        ETHERSCAN_API_KEY: etherscanApiKey,
        ETH_RPC_URL: rpcUrl,
      },
    });
    console.log(`  ✅ ${contractId} verified successfully`);
  } catch (err: any) {
    console.error(`  ❌ Failed to verify ${contractId}: ${err.message}`);
    throw err;
  }
}
