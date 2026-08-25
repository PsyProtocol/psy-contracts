import { task, types } from "hardhat/config";

task("governance:build", "Build or execute a Direct, Safe, Timelock, or Safe+Timelock transaction")
  .addParam("target", "Inner transaction target", undefined, types.string)
  .addParam("data", "Inner transaction calldata", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { target: string; data: string; executionTime?: string }) => {
    const { dryRunEncodedData } = await import("../helpers/contracts-helpers");
    await dryRunEncodedData(args.target, args.data, args.executionTime);
  });

task("governance:decode", "Decode a protocol, Safe proposal, or nested Timelock transaction")
  .addOptionalParam("target", "Transaction target", undefined, types.string)
  .addOptionalParam("data", "Transaction calldata", undefined, types.string)
  .addOptionalParam("file", "Safe proposal JSON file", undefined, types.string)
  .setAction(async (args: { target?: string; data?: string; file?: string }) => {
    const { decodeGovernanceTransaction, decodeSafeProposalFile } = await import("../helpers/transaction-decoder");
    if (args.file) {
      console.log(JSON.stringify(decodeSafeProposalFile(args.file), null, 2));
      return;
    }
    if (!args.target || !args.data) throw new Error("provide --file or both --target and --data");
    console.log(JSON.stringify(decodeGovernanceTransaction(args.target, args.data), null, 2));
  });

task("timelock:status", "Inspect a Timelock action's queue/readiness/expiry state")
  .addParam("target", "Inner transaction target", undefined, types.string)
  .addParam("data", "Inner transaction calldata", undefined, types.string)
  .addParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { target: string; data: string; executionTime: string }) => {
    const { getTimelockActionStatus } = await import("../helpers/timelock-helpers");
    const result = await getTimelockActionStatus(args.target, args.data, args.executionTime);
    const { timeLock: _timeLock, ...printable } = result;
    console.log(JSON.stringify(printable, null, 2));
  });

task("bridge:set-flow-config", "Set one token's Bridge flow-limit config with the current on-chain hash")
  .addParam("token", "Canonical token address", undefined, types.string)
  .addOptionalParam("manifest", "Flow-limit manifest path", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { token: string; manifest?: string; executionTime?: string }) => {
    const configPath = args.manifest || process.env.BRIDGE_FLOW_LIMITS_FILE;
    if (!configPath) throw new Error("--manifest or BRIDGE_FLOW_LIMITS_FILE is required");
    const { setBridgeTokenFlowConfig } = await import("../scripts/governance/bridgeFlowConfig");
    await setBridgeTokenFlowConfig(args.token, configPath, args.executionTime);
  });

task("governance:migrate-permissions", "Build the atomic Safe batch that transfers protocol control to Timelock")
  .addParam("legacy", "Comma-separated legacy admin accounts", undefined, types.string)
  .setAction(async (args: { legacy: string }) => {
    const { buildProtocolPermissionMigration } = await import("../scripts/governance/permissions");
    await buildProtocolPermissionMigration(args.legacy);
  });

task("governance:verify-permissions", "Verify Timelock ownership/roles and supplied legacy admin removal")
  .addParam("legacy", "Comma-separated legacy admin accounts", undefined, types.string)
  .setAction(async (args: { legacy: string }) => {
    const { verifyProtocolPermissions } = await import("../scripts/governance/permissions");
    await verifyProtocolPermissions(args.legacy);
  });

task("governance:transfer-timelock-admin", "Build old-Safe action to nominate a new Timelock admin Safe")
  .addParam("newAdmin", "New Governance Safe", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { newAdmin: string; executionTime?: string }) => {
    const { buildTimelockAdminTransfer } = await import("../scripts/governance/permissions");
    await buildTimelockAdminTransfer(args.newAdmin, args.executionTime);
  });

task("governance:accept-timelock-admin", "Build the pending new Safe's direct acceptAdmin transaction")
  .setAction(async () => {
    const { buildTimelockAdminAcceptance } = await import("../scripts/governance/permissions");
    await buildTimelockAdminAcceptance();
  });
