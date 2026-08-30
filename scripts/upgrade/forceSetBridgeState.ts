import { BigNumber, ethers } from "ethers";
import { dryRunEncodedData, getDeployedContract, waitForTx } from "../../helpers/contracts-helpers";
import { DRY_RUN, GLOBAL_OVERRIDES } from "../../helpers/hardhat-constants";

type BridgePrefix = "EXPECTED" | "NEW";
type BridgeScalarField = "DEPOSIT_ROOT" | "PROVED_DEPOSIT_COUNT" | "PENDING_DEPOSIT_COUNT";
type BridgeEnvName = `${BridgePrefix}_BRIDGE_${BridgeScalarField}` | `${BridgePrefix}_BRIDGE_DEPOSIT_FRONTIER_JSON`;

function requireEnv(name: BridgeEnvName): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseUint256(name: BridgeEnvName): BigNumber {
  const value = requireEnv(name);
  if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`${name} must be a decimal uint256`);
  const parsed = BigNumber.from(value);
  if (parsed.gte(BigNumber.from(2).pow(256))) throw new Error(`${name} must be a decimal uint256`);
  return parsed;
}

function parseBytes32(name: BridgeEnvName): string {
  const value = requireEnv(name);
  if (!ethers.utils.isHexString(value, 32)) throw new Error(`${name} must be a 32-byte hex value`);
  return value;
}

function parseFrontier(name: BridgeEnvName): string[] {
  const value = requireEnv(name);
  let frontier: unknown;
  try {
    frontier = JSON.parse(value);
  } catch {
    throw new Error(`${name} must be valid JSON`);
  }
  if (!Array.isArray(frontier) || frontier.length !== 32) {
    throw new Error(`${name} must be a JSON array of exactly 32 entries`);
  }
  for (let i = 0; i < frontier.length; i++) {
    if (typeof frontier[i] !== "string" || !ethers.utils.isHexString(frontier[i], 32)) {
      throw new Error(`${name}[${i}] must be a 32-byte hex value`);
    }
  }
  return frontier;
}

function stateFromEnv(prefix: BridgePrefix) {
  return {
    depositRoot: parseBytes32(`${prefix}_BRIDGE_DEPOSIT_ROOT`),
    provedDepositCount: parseUint256(`${prefix}_BRIDGE_PROVED_DEPOSIT_COUNT`),
    pendingDepositCount: parseUint256(`${prefix}_BRIDGE_PENDING_DEPOSIT_COUNT`),
    depositFrontier: parseFrontier(`${prefix}_BRIDGE_DEPOSIT_FRONTIER_JSON`),
  };
}

export async function forceSetBridgeState(executionTime?: string) {
  const expected = stateFromEnv("EXPECTED");
  const target = stateFromEnv("NEW");
  if (target.provedDepositCount.gt(target.pendingDepositCount)) {
    throw new Error("NEW_BRIDGE_PROVED_DEPOSIT_COUNT must not exceed NEW_BRIDGE_PENDING_DEPOSIT_COUNT");
  }
  if (target.provedDepositCount.gt(expected.provedDepositCount)) {
    throw new Error("NEW_BRIDGE_PROVED_DEPOSIT_COUNT must not exceed EXPECTED_BRIDGE_PROVED_DEPOSIT_COUNT");
  }
  if (target.pendingDepositCount.gt(expected.pendingDepositCount)) {
    throw new Error("NEW_BRIDGE_PENDING_DEPOSIT_COUNT must not exceed EXPECTED_BRIDGE_PENDING_DEPOSIT_COUNT");
  }
  const bridge = await getDeployedContract("Bridge");
  const args = [expected, target] as const;
  const data = bridge.interface.encodeFunctionData("forceSetState", args);

  if (DRY_RUN) {
    await dryRunEncodedData(bridge.address, data, executionTime);
  } else {
    await waitForTx(await bridge.forceSetState(...args, GLOBAL_OVERRIDES));
  }
  return { target: bridge.address, data, args };
}

if (require.main === module) {
  forceSetBridgeState(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
