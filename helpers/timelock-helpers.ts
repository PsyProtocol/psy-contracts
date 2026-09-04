import { BigNumber, Contract } from "ethers";
import { deployments, ethers } from "hardhat";
import {
  TIMELOCK_ETA_BUFFER_SECONDS,
  TIMELOCK_OPERATION,
  TimeLockOperation,
} from "./hardhat-constants";

export type TimelockAction = [string, number, string, string, string];

export type TimelockData = {
  timeLock: Contract;
  action: TimelockAction;
  actionHash: string;
  queueData: string;
  executeData: string;
  cancelData: string;
  newTarget: string;
  newData: string;
};

export type TimelockActionStatus = TimelockData & {
  queued: boolean;
  now: string;
  earliestQueueExecutionTime: string;
  readyAt: string;
  expiresAt: string;
  state: "NotQueued" | "Waiting" | "Ready" | "Expired";
};

export async function getTimeLockExecutor(): Promise<Contract> {
  const deployment = await deployments.get("ExecutorWithTimelock");
  return ethers.getContractAt(deployment.abi, deployment.address);
}

export async function getExecutionTime(executionTime?: string): Promise<string> {
  if (executionTime) return executionTime;
  if (!Number.isSafeInteger(TIMELOCK_ETA_BUFFER_SECONDS) || TIMELOCK_ETA_BUFFER_SECONDS < 1) {
    throw new Error("TIMELOCK_ETA_BUFFER_SECONDS must be a positive safe integer");
  }
  const timelock = await getTimeLockExecutor();
  const delay = await timelock.getDelay();
  const block = await ethers.provider.getBlock("latest");
  return BigNumber.from(block.timestamp).add(delay).add(TIMELOCK_ETA_BUFFER_SECONDS).toString();
}

async function buildTimeLockData(target: string, data: string, executionTime: string): Promise<TimelockData> {
  const timeLock = await getTimeLockExecutor();
  const action: TimelockAction = [target, 0, "", data, executionTime];
  const actionHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "string", "bytes", "uint256"],
      action,
    ),
  );
  const queueData = timeLock.interface.encodeFunctionData("queueTransaction", action);
  const executeData = timeLock.interface.encodeFunctionData("executeTransaction", action);
  const cancelData = timeLock.interface.encodeFunctionData("cancelTransaction", action);
  return { timeLock, action, actionHash, queueData, executeData, cancelData, newTarget: timeLock.address, newData: queueData };
}

export async function getTimeLockData(
  target: string,
  data: string,
  executionTime?: string,
  operation: TimeLockOperation = TIMELOCK_OPERATION,
): Promise<TimelockData> {
  if (!Object.values(TimeLockOperation).includes(operation)) {
    throw new Error("TIMELOCK_OPERATION must be Queue, Execute, or Cancel");
  }
  if (operation !== TimeLockOperation.Queue && !executionTime) {
    throw new Error("executionTime is required for Execute and Cancel; reuse the exact queued ETA");
  }
  const eta = await getExecutionTime(executionTime);
  const result = await buildTimeLockData(target, data, eta);
  if (operation === TimeLockOperation.Queue) {
    const block = await ethers.provider.getBlock("latest");
    const minimumEta = BigNumber.from(block.timestamp).add(await result.timeLock.getDelay());
    if (BigNumber.from(eta).lt(minimumEta)) {
      throw new Error(`executionTime ${eta} is below the current minimum ${minimumEta.toString()}`);
    }
  }
  result.newData = operation === TimeLockOperation.Execute
    ? result.executeData
    : operation === TimeLockOperation.Cancel
      ? result.cancelData
      : result.queueData;
  return result;
}

export async function getTimelockActionStatus(
  target: string,
  data: string,
  executionTime: string,
): Promise<TimelockActionStatus> {
  const result = await buildTimeLockData(target, data, executionTime);
  const block = await ethers.provider.getBlock("latest");
  const now = BigNumber.from(block.timestamp);
  const delay = await result.timeLock.getDelay();
  const gracePeriod = await result.timeLock.GRACE_PERIOD();
  const readyAt = BigNumber.from(executionTime);
  const expiresAt = readyAt.add(gracePeriod);
  const queued = await result.timeLock.isActionQueued(result.actionHash);
  const state = !queued ? "NotQueued" : now.lt(readyAt) ? "Waiting" : now.lte(expiresAt) ? "Ready" : "Expired";
  return {
    ...result,
    queued,
    now: now.toString(),
    earliestQueueExecutionTime: now.add(delay).toString(),
    readyAt: readyAt.toString(),
    expiresAt: expiresAt.toString(),
    state,
  };
}
