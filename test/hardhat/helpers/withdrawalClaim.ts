import { ethers } from "hardhat";
import type { BigNumberish, Contract } from "ethers";

export const ORCHESTRATION_PROOF = [1n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];
export const ZERO_PROOF = new Array<bigint>(8).fill(0n);
export const word = (value: BigNumberish): string => ethers.utils.hexZeroPad(ethers.BigNumber.from(value).toHexString(), 32);
const words = (values: BigNumberish[]): string => ethers.utils.hexConcat(values.map(word));
const domain = (label: string): string => ethers.utils.id(`PsyBridge/TwoArtifact/1/${label}`);
const rootWords = (root: string): bigint[] => [192n, 128n, 64n, 0n].map(shift => (BigInt(root) >> shift) & ((1n << 64n) - 1n));

export function buildNetworkConfig(chainId: number, bridge: string, stateManager: string, rewardPayer: string, rewardToken: string): string {
  return words([1, 0, 524288, 7, 1, 0, chainId, bridge, stateManager, 0, 0, 0, 0, 0,
    0, rewardPayer, rewardToken, 1, 18, 0, 100, 1024, 1024, 1024]);
}

export type Withdrawal = {
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destinationChainIndex?: number;
  senderUserId?: number;
};

export type BridgeWindow = [bigint[], bigint[], bigint[], string, bigint[], string, bigint[], string];

// Nonzero mock proofs exercise orchestration only, never cryptographic acceptance.
export async function buildBridgeWindow(stateManager: Contract, bridge: Contract, withdrawals: Withdrawal[] = [], endCheckpointId?: bigint): Promise<BridgeWindow> {
  const startId = BigInt((await stateManager.lastFinalizedCheckpointId()).toString());
  const startRoot = await stateManager.lastVerifiedCheckpointRoot();
  const endId = endCheckpointId ?? startId + 1n;
  const endRoot = endId === startId ? startRoot : word(endId);
  const configHash = await stateManager.configHash();
  const chainIndex = await stateManager.l1ChainIndex();
  const depositRoot = await bridge.depositRoot();
  const depositCount = await bridge.provedDepositCount();
  const withdrawalRoot = ethers.constants.HashZero;
  const end = words([endId, ...rootWords(endRoot)]);
  const starts = words([1, chainIndex, startId, ...rootWords(startRoot)]);
  const deposits = words([1, chainIndex, ...rootWords(depositRoot), ...rootWords(depositRoot), depositCount, depositCount]);
  const windowId = ethers.utils.keccak256(ethers.utils.hexConcat([domain("Window"), configHash, end, starts, deposits]));
  const header = ethers.utils.hexConcat([configHash, windowId, end]);
  const depositOpening = ethers.utils.hexConcat([header, starts, deposits, word(0)]);
  const withdrawalOpening = ethers.utils.hexConcat([header, word(1), words(rootWords(withdrawalRoot)), word(withdrawals.length), ...withdrawals.map(leaf => words([
    leaf.destinationChainIndex ?? chainIndex, leaf.senderUserId ?? 0, leaf.recipient, leaf.token, leaf.amount, leaf.nonce,
  ]))]);
  const rewardOpening = ethers.utils.hexConcat([header, word(0)]);
  const replay = endId === startId;
  const proofStartRoot = replay ? ethers.constants.HashZero : startRoot;
  const proofStartId = replay ? 0n : startId;
  const publicInputs = [
    ...rootWords(proofStartRoot), ...new Array<bigint>(16).fill(0n), ...rootWords(endRoot), endId, endId - proofStartId,
    ...rootWords(depositRoot), BigInt(depositCount.toString()), ...rootWords(withdrawalRoot),
  ];
  return [ORCHESTRATION_PROOF, publicInputs,
    ORCHESTRATION_PROOF, depositOpening, withdrawals.length ? ORCHESTRATION_PROOF : ZERO_PROOF,
    withdrawalOpening, ZERO_PROOF, rewardOpening];
}

export async function registerWithdrawal(params: Withdrawal & { bridge: Contract; stateManager: Contract }) {
  const { bridge, stateManager, ...withdrawal } = params;
  await stateManager.applyBridgeWindow(...await buildBridgeWindow(stateManager, bridge, [withdrawal]));
  return word(withdrawal.nonce);
}
