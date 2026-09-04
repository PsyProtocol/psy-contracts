// Task actions use await import(...) instead of static imports: hardhat task registration must not
// eagerly load ethers/providers, so each script is loaded only when its task actually runs.
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
  .addParam("token", "Token address configured in the flow-limit manifest", undefined, types.string)
  .addOptionalParam("manifest", "Flow-limit manifest path", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { token: string; manifest?: string; executionTime?: string }) => {
    const configPath = args.manifest || process.env.BRIDGE_FLOW_LIMITS_FILE;
    if (!configPath) throw new Error("--manifest or BRIDGE_FLOW_LIMITS_FILE is required");
    const { setBridgeTokenFlowConfig } = await import("../scripts/governance/bridgeFlowConfig");
    await setBridgeTokenFlowConfig(args.token, configPath, args.executionTime);
  });
task("bridge:force-claim-withdrawal", "Settle a reviewed pending Bridge withdrawal via governance")
  .addParam("nonce", "Pending withdrawal nonce", undefined, types.string)
  .addOptionalParam("executionTime", "Timelock execution timestamp", undefined, types.string)
  .setAction(async (args: { nonce: string; executionTime?: string }) => {
    const { forceClaimWithdrawal } = await import("../scripts/governance/bridgeFlowConfig");
    await forceClaimWithdrawal(args.nonce, args.executionTime);
  });

task("governance:migrate-permissions", "Build the atomic Safe batch that transfers protocol control to Timelock")
  .addParam("stripAdmins", "Comma-separated admin accounts to strip of all ACL roles", undefined, types.string)
  .setAction(async (args: { stripAdmins: string }) => {
    const { buildProtocolPermissionMigration } = await import("../scripts/governance/permissions");
    await buildProtocolPermissionMigration(args.stripAdmins);
  });

task("governance:verify-permissions", "Verify Timelock ownership/roles, admin role stripping, and proposer role separation")
  .addParam("stripAdmins", "Comma-separated admin accounts to strip of all ACL roles", undefined, types.string)
  .addOptionalParam("proposer", "Dedicated PROPOSER_ROLE bot address (must differ from the Timelock and Governance Safe)", undefined, types.string)
  .setAction(async (args: { stripAdmins: string; proposer?: string }) => {
    const { verifyProtocolPermissions } = await import("../scripts/governance/permissions");
    await verifyProtocolPermissions(args.stripAdmins, args.proposer);
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
