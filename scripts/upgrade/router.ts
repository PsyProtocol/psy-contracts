import { upgradeContract } from "./utils";

export async function upgradeRouter(executionTime?: string) {
  return upgradeContract("Router", "Router", executionTime);
}

if (require.main === module) {
  upgradeRouter(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
