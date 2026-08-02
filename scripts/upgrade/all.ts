import { upgradeAllContracts } from "./utils";

if (require.main === module) {
  upgradeAllContracts(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
