import { Contract } from "ethers";
import { deployments, ethers } from "hardhat";
import { DRY_RUN, DryRunExecutor, GLOBAL_OVERRIDES } from "./hardhat-constants";
import { getTimeLockData } from "./timelock-helpers";
import { proposeMultiSafeTransactions, proposeSafeTransaction, type MetaTransaction } from "./safe-helpers";

export async function waitForTx(tx: { wait: () => Promise<unknown> }): Promise<void> {
  await tx.wait();
}

export async function getDeployedContract(name: string): Promise<Contract> {
  const deployment = await deployments.get(name);
  const contract = await ethers.getContractAt(deployment.abi, deployment.address) as any;
  if (contract.address == null) contract.address = deployment.address;
  return contract;
}

export async function dryRunEncodedData(target: string, data: string, executionTime?: string): Promise<void> {
  if (DRY_RUN === DryRunExecutor.TimeLock) {
    const { actionHash, queueData, executeData, cancelData, action, timeLock } = await getTimeLockData(target, data, executionTime);
    console.log(JSON.stringify({ mode: DRY_RUN, timeLock: timeLock.address, actionHash, action, queueData, executeData, cancelData }, null, 2));
    return;
  }
  if (DRY_RUN === DryRunExecutor.SafeWithTimeLock) {
    const { newTarget, newData } = await getTimeLockData(target, data, executionTime);
    await proposeSafeTransaction(newTarget, newData);
    return;
  }
  if (DRY_RUN === DryRunExecutor.Safe) {
    await proposeSafeTransaction(target, data);
    return;
  }
  if (DRY_RUN === DryRunExecutor.Run) {
    const [signer] = await ethers.getSigners();
    const tx = await signer.sendTransaction({ to: target, data, ...GLOBAL_OVERRIDES });
    await waitForTx(tx);
    return;
  }
  console.log(JSON.stringify({ mode: "None", target, data }, null, 2));
}

export async function dryRunMultipleEncodedData(
  targets: string[],
  data: string[],
  executionTimes: Array<string | undefined> = [],
): Promise<void> {
  if (targets.length !== data.length) throw new Error("targets/data length mismatch");
  if (DRY_RUN === DryRunExecutor.TimeLock) {
    for (let i = 0; i < targets.length; i++) {
      await dryRunEncodedData(targets[i], data[i], executionTimes[i]);
    }
    return;
  }
  if (DRY_RUN === DryRunExecutor.SafeWithTimeLock) {
    const txs: MetaTransaction[] = [];
    for (let i = 0; i < targets.length; i++) {
      const { newTarget, newData } = await getTimeLockData(targets[i], data[i], executionTimes[i]);
      txs.push({ to: newTarget, data: newData, value: "0" });
    }
    await proposeMultiSafeTransactions(txs);
    return;
  }
  if (DRY_RUN === DryRunExecutor.Safe) {
    await proposeMultiSafeTransactions(targets.map((to, i) => ({ to, data: data[i], value: "0" })));
    return;
  }
  for (let i = 0; i < targets.length; i++) {
    await dryRunEncodedData(targets[i], data[i], executionTimes[i]);
  }
}
