import { task, types } from "hardhat/config";

const upgrade = task("upgrade", "Upgrade a transparent-proxy Psy contract")
  .addParam("contract", "Deployment name", undefined, types.string)
  .addOptionalParam("implementation", "Implementation contract name", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string);

upgrade.setAction(async (args: { contract: string; implementation?: string; executionTime?: string }) => {
  const { upgradeContract, isUpgradeableContractName } = await import("../scripts/upgrade/utils");
  if (!isUpgradeableContractName(args.contract)) {
    throw new Error(`Unsupported upgrade target: ${args.contract}`);
  }
  await upgradeContract(args.contract, args.implementation, args.executionTime);
});

task("upgrade:all", "Upgrade all Psy transparent-proxy contracts")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { upgradeAllContracts } = await import("../scripts/upgrade/utils");
    await upgradeAllContracts(args.executionTime);
  });

task("upgrade:state-manager", "Upgrade StateManager")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { upgradeStateManager } = await import("../scripts/upgrade/stateManager");
    console.time("upgrade StateManager");
    await upgradeStateManager(args.executionTime);
    console.timeEnd("upgrade StateManager");
  });

task("upgrade:bridge", "Upgrade Bridge")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { upgradeBridge } = await import("../scripts/upgrade/bridge");
    console.time("upgrade Bridge");
    await upgradeBridge(args.executionTime);
    console.timeEnd("upgrade Bridge");
  });

task("upgrade:router", "Upgrade Router")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { upgradeRouter } = await import("../scripts/upgrade/router");
    console.time("upgrade Router");
    await upgradeRouter(args.executionTime);
    console.timeEnd("upgrade Router");
  });

task("upgrade:gateway", "Upgrade ERC20Gateway and/or ETHGateway")
  .addOptionalParam("gateway", "erc20, eth, or all", "all", types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { gateway: string; executionTime?: string }) => {
    const { upgradeERC20Gateway, upgradeETHGateway } = await import("../scripts/upgrade/gateway");
    console.time("upgrade gateway");
    if (args.gateway !== "erc20" && args.gateway !== "eth" && args.gateway !== "all") {
      throw new Error("gateway must be erc20, eth, or all");
    }
    if (args.gateway === "erc20" || args.gateway === "all") await upgradeERC20Gateway(args.executionTime);
    if (args.gateway === "eth" || args.gateway === "all") await upgradeETHGateway(args.executionTime);
    console.timeEnd("upgrade gateway");
  });

task("state-manager:force-set-state", "Encode or execute StateManager.forceSetState")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { forceSetState } = await import("../scripts/upgrade/forceSetState");
    await forceSetState(args.executionTime);
  });

task("bridge:rescue", "Encode or execute Bridge rescueERC20/rescueNative/rescueWETHAsNative")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { rescueBridgeFunds } = await import("../scripts/upgrade/rescueBridgeFunds");
    await rescueBridgeFunds(args.executionTime);
  });
