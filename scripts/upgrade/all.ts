import { upgradeAllContracts } from "./utils";
import { getBridgeFlowLimitInitData } from "./bridge";

if (require.main === module) {
  getBridgeFlowLimitInitData()
    .then((initData) => upgradeAllContracts(process.env.TIMELOCK_EXECUTION_TIME, initData))
    .catch((err: unknown) => {
      console.error(err);
      process.exit(1);
    });
}
