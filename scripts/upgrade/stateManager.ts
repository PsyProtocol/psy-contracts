import { upgradeContract } from "./utils";

export async function upgradeStateManager(executionTime?: string) {
  return upgradeContract("StateManager", "StateManager", executionTime);
}

if (require.main === module) {
  upgradeStateManager(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
