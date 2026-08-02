import { dryRunEncodedData, getDeployedContract, waitForTx } from "../../helpers/contracts-helpers";
import { DRY_RUN, GLOBAL_OVERRIDES } from "../../helpers/hardhat-constants";

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

  if (DRY_RUN) {
    await dryRunEncodedData(bridge.address, data, executionTime);
  } else {
    if (mode === "erc20") {
      await waitForTx(await bridge.rescueERC20(required("RESCUE_TOKEN"), to, amount, GLOBAL_OVERRIDES));
    } else if (mode === "native") {
      await waitForTx(await bridge.rescueNative(to, amount, GLOBAL_OVERRIDES));
    } else {
      await waitForTx(await bridge.rescueWETHAsNative(to, amount, GLOBAL_OVERRIDES));
    }
  }
  return { target: bridge.address, data, mode, to, amount };
}

if (require.main === module) {
  rescueBridgeFunds(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
