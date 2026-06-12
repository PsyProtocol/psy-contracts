import { execSync } from "child_process";
import type { Artifact } from "hardhat/types";
import {
  ETHERSCAN_KEY,
  COMPILER_VERSION,
  COMPILER_OPTIMIZER_RUNS,
} from "./hardhat-constants";

export type LibraryAddresses = Record<string, string>;

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

  // Build the forge verify-contract command
  let cmd = `ETHERSCAN_API_KEY=${etherscanApiKey} ETH_RPC_URL=${rpcUrl}`;
  if (verifierUrl) {
    cmd += ` VERIFIER_URL=${verifierUrl}`;
  }
  cmd += ` forge verify-contract ${address}`;

  cmd += ` --chain-id ${chainId}`;
  cmd += ` --num-of-optimizations ${COMPILER_OPTIMIZER_RUNS}`;
  cmd += ` --watch`;
  cmd += ` --compiler-version v${COMPILER_VERSION}`;
  cmd += ` ${contractFQN}`;

  // Constructor args via cast abi-encode
  if (constructorArgs.length > 0 && artifact) {
    const ctorAbi = (artifact.abi ?? []).find(
      (item: any) => item.type === "constructor",
    );
    if (ctorAbi && ctorAbi.inputs && ctorAbi.inputs.length > 0) {
      const argTypes = ctorAbi.inputs.map((x: any) => x.type).join(",");
      const argValues = constructorArgs
        .map((x) => (Array.isArray(x) ? `"[${x.join(",")}"]` : `"${x}"`))
        .join(" ");

      const encoded = execSync(
        `cast abi-encode "constructor(${argTypes})" ${argValues}`,
        { encoding: "utf8" },
      ).trim();
      cmd += ` --constructor-args ${encoded}`;
    }
  }

  // Libraries (forge format: --libraries sourceName:LibName:0x...)
  if (libraries && Object.keys(libraries).length > 0) {
    const libFlags = Object.entries(libraries)
      .map(([libName, libAddress]) => `--libraries ${libName}:${libAddress}`)
      .join(" ");
    cmd += ` ${libFlags}`;
  }

  console.log(`\n[VERIFY] ${contractId}`);
  console.log(`  address: ${address}`);
  console.log(`  FQN:     ${contractFQN}`);
  console.log(`  running: forge verify-contract ...`);

  try {
    execSync(cmd, { stdio: "inherit", encoding: "utf8" });
    console.log(`  ✅ ${contractId} verified successfully`);
  } catch (err: any) {
    console.error(`  ❌ Failed to verify ${contractId}: ${err.message}`);
    throw err;
  }
}
