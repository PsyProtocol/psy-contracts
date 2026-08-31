import { BigNumber, ethers } from "ethers";
import { dryRunEncodedData, getDeployedContract, waitForTx } from "../../helpers/contracts-helpers";
import { DRY_RUN, GLOBAL_OVERRIDES } from "../../helpers/hardhat-constants";

const STATE_FIELDS = [
  "LAST_FINALIZED_CHECKPOINT_ID",
  "LAST_VERIFIED_CHECKPOINT_ROOT",
  "LAST_VERIFIED_DEPOSIT_TREE_ROOT",
  "LAST_VERIFIED_WITHDRAWAL_TREE_ROOT",
  "WITHDRAWAL_SUBTREE_ROOT",
] as const;

type StatePrefix = "EXPECTED" | "NEW";
type StateField = typeof STATE_FIELDS[number];
type StateEnvName = `${StatePrefix}_${StateField}`;

function requireEnv(name: StateEnvName): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseUint64(name: StateEnvName): BigNumber {
  const value = requireEnv(name);
  if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`${name} must be a decimal uint64`);
  const parsed = BigNumber.from(value);
  if (parsed.gte(BigNumber.from(2).pow(64))) throw new Error(`${name} must be a decimal uint64`);
  return parsed;
}

function parseBytes32(name: StateEnvName): string {
  const value = requireEnv(name);
  if (!ethers.utils.isHexString(value, 32)) throw new Error(`${name} must be a 32-byte hex value`);
  return value;
}

function stateFromEnv(prefix: StatePrefix) {
  return {
    lastFinalizedCheckpointId: parseUint64(`${prefix}_LAST_FINALIZED_CHECKPOINT_ID`),
    lastVerifiedCheckpointRoot: parseBytes32(`${prefix}_LAST_VERIFIED_CHECKPOINT_ROOT`),
    lastVerifiedDepositTreeRoot: parseBytes32(`${prefix}_LAST_VERIFIED_DEPOSIT_TREE_ROOT`),
    lastVerifiedWithdrawalTreeRoot: parseBytes32(`${prefix}_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT`),
    withdrawalSubtreeRoot: parseBytes32(`${prefix}_WITHDRAWAL_SUBTREE_ROOT`),
  };
}

export async function forceSetState(executionTime?: string) {
  const expected = stateFromEnv("EXPECTED");
  const target = stateFromEnv("NEW");
  if (target.lastFinalizedCheckpointId.gt(expected.lastFinalizedCheckpointId)) {
    throw new Error("NEW_LAST_FINALIZED_CHECKPOINT_ID must not exceed EXPECTED_LAST_FINALIZED_CHECKPOINT_ID");
  }
  const stateManager = await getDeployedContract("StateManager");
  const args = [expected, target] as const;
  const data = stateManager.interface.encodeFunctionData("forceSetState", args);

  if (DRY_RUN) {
    await dryRunEncodedData(stateManager.address, data, executionTime);
  } else {
    await waitForTx(await stateManager.forceSetState(...args, GLOBAL_OVERRIDES));
  }
  return { target: stateManager.address, data, args };
}

if (require.main === module) {
  forceSetState(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
