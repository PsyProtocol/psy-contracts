import {
  dryRunMultipleEncodedData,
  getDeployedContract,
  waitForTx,
} from "../../helpers/contracts-helpers";
import {
  DRY_RUN,
  DryRunExecutor,
  GLOBAL_OVERRIDES,
  TIMELOCK_OPERATION,
  TimeLockOperation,
} from "../../helpers/hardhat-constants";
import { getExecutionTime } from "../../helpers/timelock-helpers";
import { ethers } from "hardhat";

type RescueMode = "erc20" | "native" | "weth-native";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function modeFromEnv(): RescueMode {
  const value = required("RESCUE_MODE");
  if (value !== "erc20" && value !== "native" && value !== "weth-native") {
    throw new Error("RESCUE_MODE must be erc20, native, or weth-native");
  }
  return value;
}

export async function rescueBridgeFunds(executionTime?: string) {
  const bridge = await getDeployedContract("Bridge");
  const mode = modeFromEnv();
  const to = required("RESCUE_TO");
  const amount = required("RESCUE_AMOUNT");
  const data = mode === "erc20"
    ? bridge.interface.encodeFunctionData("rescueERC20", [required("RESCUE_TOKEN"), to, amount])
    : mode === "native"
      ? bridge.interface.encodeFunctionData("rescueNative", [to, amount])
      : bridge.interface.encodeFunctionData("rescueWETHAsNative", [to, amount]);
  const [globalPauseFlags] = await bridge.getPauseFlags(ethers.constants.AddressZero);
  const pauseData = globalPauseFlags === 7 || globalPauseFlags.toString() === "7"
    ? undefined
    : bridge.interface.encodeFunctionData("setGlobalPauseFlags", [7]);

  if (DRY_RUN) {
    const payloads = pauseData ? [pauseData, data] : [data];
    const routedThroughTimelock = DRY_RUN === DryRunExecutor.TimeLock
      || DRY_RUN === DryRunExecutor.SafeWithTimeLock;
    const resolvedExecutionTime = routedThroughTimelock
      && TIMELOCK_OPERATION === TimeLockOperation.Queue
      && !executionTime
      ? await getExecutionTime()
      : executionTime;
    await dryRunMultipleEncodedData(
      payloads.map(() => bridge.address),
      payloads,
      payloads.map(() => resolvedExecutionTime),
    );
  } else {
    if (pauseData) await waitForTx(await bridge.setGlobalPauseFlags(7, GLOBAL_OVERRIDES));
    if (mode === "erc20") {
      await waitForTx(await bridge.rescueERC20(required("RESCUE_TOKEN"), to, amount, GLOBAL_OVERRIDES));
    } else if (mode === "native") {
      await waitForTx(await bridge.rescueNative(to, amount, GLOBAL_OVERRIDES));
    } else {
      await waitForTx(await bridge.rescueWETHAsNative(to, amount, GLOBAL_OVERRIDES));
    }
  }
  return { target: bridge.address, pauseData, data, mode, to, amount };
}

if (require.main === module) {
  rescueBridgeFunds(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
