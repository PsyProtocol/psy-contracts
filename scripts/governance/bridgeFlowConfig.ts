import { Contract } from "ethers";
import { ethers } from "hardhat";
import { dryRunEncodedData, getDeployedContract, waitForTx } from "../../helpers/contracts-helpers";
import { DRY_RUN, DryRunExecutor, GLOBAL_OVERRIDES } from "../../helpers/hardhat-constants";
import { FlowLimitConfig, getTokenFlowConfigFromManifest } from "../upgrade/bridge";

const TOKEN_FLOW_CONFIG_TUPLE =
  "tuple(uint128 minDepositAmount,uint128 depositBucketCapacity," +
  "uint128 depositRefillPerSecond,uint128 custodyCap,uint128 smallWithdrawalMax," +
  "uint128 lifetimeWithdrawalThreshold," +
  "uint32 smallWithdrawalDelay,uint32 mediumWithdrawalDelay,uint32 thresholdExceededWithdrawalDelay,bool configured)";

export type TokenFlowConfigUpdate = {
  target: string;
  token: string;
  expectedConfigHash: string;
  nextConfigHash: string;
  config: FlowLimitConfig;
  data: string;
};
export type ForceWithdrawalClaim = {
  target: string;
  nonce: string;
  data: string;
};

export function buildForceWithdrawalClaim(
  bridge: Contract,
  nonce: string,
): ForceWithdrawalClaim {
  const normalizedNonce = ethers.utils.hexZeroPad(nonce, 32);
  return {
    target: bridge.address,
    nonce: normalizedNonce,
    data: bridge.interface.encodeFunctionData("forceClaimWithdrawal", [normalizedNonce]),
  };
}

export async function buildTokenFlowConfigUpdate(
  bridge: Contract,
  token: string,
  config: FlowLimitConfig,
): Promise<TokenFlowConfigUpdate> {
  const normalizedToken = ethers.utils.getAddress(token);
  const expectedConfigHash = await bridge.getTokenFlowConfigHash(normalizedToken);
  const nextConfigHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["address", TOKEN_FLOW_CONFIG_TUPLE], [normalizedToken, config]),
  );
  return {
    target: bridge.address,
    token: normalizedToken,
    expectedConfigHash,
    nextConfigHash,
    config,
    data: bridge.interface.encodeFunctionData("setTokenFlowConfig", [
      normalizedToken,
      config,
      expectedConfigHash,
    ]),
  };
}

export async function setBridgeTokenFlowConfig(
  token: string,
  configPath: string,
  executionTime?: string,
): Promise<TokenFlowConfigUpdate> {
  const bridge = await getDeployedContract("Bridge");
  const config = getTokenFlowConfigFromManifest(configPath, token);
  const update = await buildTokenFlowConfigUpdate(bridge, token, config);
  console.log(JSON.stringify(update, null, 2));
  if (DRY_RUN) {
    await dryRunEncodedData(update.target, update.data, executionTime);
  } else {
    await waitForTx(await bridge.setTokenFlowConfig(
      update.token,
      update.config,
      update.expectedConfigHash,
      GLOBAL_OVERRIDES,
    ));
  }
  return update;
}
export async function forceClaimWithdrawal(
  nonce: string,
  executionTime?: string,
): Promise<ForceWithdrawalClaim> {
  if (DRY_RUN !== DryRunExecutor.TimeLock && DRY_RUN !== DryRunExecutor.SafeWithTimeLock) {
    throw new Error("forceClaimWithdrawal must use DRY_RUN=TimeLock or DRY_RUN=SafeWithTimeLock");
  }
  const bridge = await getDeployedContract("Bridge");
  const claim = buildForceWithdrawalClaim(bridge, nonce);
  console.log(JSON.stringify(claim, null, 2));
  await dryRunEncodedData(claim.target, claim.data, executionTime);
  return claim;
}
