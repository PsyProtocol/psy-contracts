import { BigNumber, Contract } from "ethers";
import { deployments, ethers } from "hardhat";
import { TIMELOCK_OPERATION, TimeLockOperation } from "./hardhat-constants";

export type TimelockAction = [string, number, string, string, string, boolean];

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

export async function getTimeLockExecutor(): Promise<Contract> {
  const deployment = await deployments.get("ExecutorWithTimelock");
  return ethers.getContractAt(deployment.abi, deployment.address);
}

export async function getExecutionTime(executionTime?: string): Promise<string> {
  if (executionTime) return executionTime;
  const timelock = await getTimeLockExecutor();
  const delay = await timelock.getDelay();
  const block = await ethers.provider.getBlock("latest");
  return BigNumber.from(block.timestamp).add(delay).toString();
}

export async function getTimeLockData(target: string, data: string, executionTime?: string): Promise<TimelockData> {
  const timeLock = await getTimeLockExecutor();
  const eta = await getExecutionTime(executionTime);
  const action: TimelockAction = [target, 0, "", data, eta, false];
  const actionHash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["address", "uint256", "string", "bytes", "uint256", "bool"],
      action,
    ),
  );
  const queueData = timeLock.interface.encodeFunctionData("queueTransaction", action);
  const executeData = timeLock.interface.encodeFunctionData("executeTransaction", action);
  const cancelData = timeLock.interface.encodeFunctionData("cancelTransaction", action);
  const newData = TIMELOCK_OPERATION === TimeLockOperation.Execute
    ? executeData
    : TIMELOCK_OPERATION === TimeLockOperation.Cancel
      ? cancelData
      : queueData;
  return { timeLock, action, actionHash, queueData, executeData, cancelData, newTarget: timeLock.address, newData };
}
