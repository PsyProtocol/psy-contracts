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
  if (args.contract === "Bridge") {
    const { getBridgeWithdrawalTotalsInitData } = await import("../scripts/upgrade/bridge");
    await upgradeContract(
      args.contract,
      args.implementation,
      args.executionTime,
      await getBridgeWithdrawalTotalsInitData(),
    );
    return;
  }
  await upgradeContract(args.contract, args.implementation, args.executionTime);
});

task("upgrade:all", "Upgrade all Psy transparent-proxy contracts")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { upgradeAllContracts } = await import("../scripts/upgrade/utils");
    const { getBridgeWithdrawalTotalsInitData } = await import("../scripts/upgrade/bridge");
    await upgradeAllContracts(args.executionTime, await getBridgeWithdrawalTotalsInitData());
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

task("state-manager:revoke-checkpoint-tree-roots", "Encode or execute named checkpoint-tree-root revocation")
  .addParam("rootsJson", "JSON array of roots or path to a JSON file", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { rootsJson: string; executionTime?: string }) => {
    // Hardhat config loads tasks before its runtime exists; helpers import that runtime.
    const { revokeCheckpointTreeRoots } = await import("../scripts/upgrade/forceSetState");
    await revokeCheckpointTreeRoots(args.rootsJson, args.executionTime);
  });

task("state-manager:revoke-known-subtree-roots", "Encode or execute named subtree membership revocation")
  .addParam("depositRootsJson", "Deposit subtree roots JSON array or file path", undefined, types.string)
  .addParam("withdrawalRootsJson", "Withdrawal subtree roots JSON array or file path", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { depositRootsJson: string; withdrawalRootsJson: string; executionTime?: string }) => {
    // Hardhat config loads tasks before its runtime exists; helpers import that runtime.
    const { revokeKnownSubtreeRoots } = await import("../scripts/upgrade/forceSetState");
    await revokeKnownSubtreeRoots(args.depositRootsJson, args.withdrawalRootsJson, args.executionTime);
  });

task("state-manager:set-checkpoint-tree-roots-clean", "Encode or execute the checkpoint-tree-root clean flag")
  .addParam("clean", "Whether checkpoint-tree-root cleanup is complete", undefined, types.boolean)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { clean: boolean; executionTime?: string }) => {
    // Hardhat config loads tasks before its runtime exists; helpers import that runtime.
    const { setCheckpointTreeRootsClean } = await import("../scripts/upgrade/forceSetState");
    await setCheckpointTreeRootsClean(args.clean, args.executionTime);
  });

task("bridge:force-set-state", "Encode or execute Bridge.forceSetState")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { forceSetBridgeState } = await import("../scripts/upgrade/forceSetBridgeState");
    await forceSetBridgeState(args.executionTime);
  });

task("bridge:rescue", "Encode or execute Bridge rescueERC20/rescueNative/rescueWETHAsNative")
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { executionTime?: string }) => {
    const { rescueBridgeFunds } = await import("../scripts/upgrade/rescueBridgeFunds");
    await rescueBridgeFunds(args.executionTime);
  });
