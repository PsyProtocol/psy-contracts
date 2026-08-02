import { upgradeContract } from "./utils";

export async function upgradeBridge(executionTime?: string) {
  return upgradeContract("Bridge", "Bridge", executionTime);
}

if (require.main === module) {
  upgradeBridge(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
