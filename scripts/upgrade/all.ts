import { upgradeAllContracts } from "./utils";
import { getBridgeWithdrawalTotalsInitData } from "./bridge";

if (require.main === module) {
  getBridgeWithdrawalTotalsInitData()
    .then((initData) => upgradeAllContracts(process.env.TIMELOCK_EXECUTION_TIME, initData))
    .catch((err: unknown) => {
      console.error(err);
      process.exit(1);
    });
}
