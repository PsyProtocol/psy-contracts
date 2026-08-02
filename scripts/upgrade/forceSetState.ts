import { dryRunEncodedData, getDeployedContract, waitForTx } from "../../helpers/contracts-helpers";
import { DRY_RUN, DryRunExecutor, GLOBAL_OVERRIDES } from "../../helpers/hardhat-constants";

const REQUIRED = [
  "NEW_LAST_FINALIZED_CHECKPOINT_ID",
  "NEW_LAST_VERIFIED_CHECKPOINT_ROOT",
  "NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT",
  "NEW_DEPOSIT_SUBTREE_ROOT",
  "NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT",
  "NEW_WITHDRAWAL_SUBTREE_ROOT",
] as const;

function requireEnv(name: typeof REQUIRED[number]): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

export async function forceSetState(executionTime?: string) {
  const stateManager = await getDeployedContract("StateManager");
  const args = [
    requireEnv("NEW_LAST_FINALIZED_CHECKPOINT_ID"),
    requireEnv("NEW_LAST_VERIFIED_CHECKPOINT_ROOT"),
    requireEnv("NEW_LAST_VERIFIED_DEPOSIT_TREE_ROOT"),
    requireEnv("NEW_DEPOSIT_SUBTREE_ROOT"),
    requireEnv("NEW_LAST_VERIFIED_WITHDRAWAL_TREE_ROOT"),
    requireEnv("NEW_WITHDRAWAL_SUBTREE_ROOT"),
  ];
  const data = stateManager.interface.encodeFunctionData("forceSetState", args);

  if (DRY_RUN) {
    await dryRunEncodedData(stateManager.address, data, executionTime);
  } else {
    if (DRY_RUN === DryRunExecutor.Run) throw new Error("unreachable");
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
