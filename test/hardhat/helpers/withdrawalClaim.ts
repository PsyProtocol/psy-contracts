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

export type BridgeWindow = [bigint[], string, bigint[], string];

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
  const end = words([endId, ...rootWords(endRoot)]);
  const starts = words([1, chainIndex, startId, ...rootWords(startRoot)]);
  const deposits = words([1, chainIndex, ...rootWords(depositRoot), ...rootWords(depositRoot), depositCount, depositCount]);
  const windowId = ethers.utils.keccak256(ethers.utils.hexConcat([domain("Window"), configHash, end, starts, deposits]));
  const header = ethers.utils.hexConcat([configHash, windowId, end]);
  const depositOpening = ethers.utils.hexConcat([header, starts, deposits, word(0)]);
  const span = endId > startId ? endId - startId : 1n;
  const zeroRoot = words(rootWords(ethers.constants.HashZero));
  const settlementOpening = ethers.utils.hexConcat([
    header, words(new Array<bigint>(8).fill(0n)), words(new Array<bigint>(8).fill(0n)), word(1),
    words(rootWords(startRoot)), word(span), word(1), words(rootWords(depositRoot)), word(depositCount),
    zeroRoot, word(withdrawals.length),
    ...withdrawals.map(leaf => words([
      leaf.destinationChainIndex ?? chainIndex, leaf.senderUserId ?? 0, leaf.recipient, leaf.token, leaf.amount, leaf.nonce,
    ])),
    zeroRoot, zeroRoot, word(0), word(0),
  ]);
  return [ORCHESTRATION_PROOF, depositOpening, ORCHESTRATION_PROOF, settlementOpening];
}

const LEAF = ethers.utils.id("PsyBridge/TwoArtifact/1/Leaf");
const EMPTY = ethers.utils.id("PsyBridge/TwoArtifact/1/Empty");
const NODE = ethers.utils.id("PsyBridge/TwoArtifact/1/Node");
const RECORD = ethers.utils.id("PsyBridge/TwoArtifact/1/Record");
const MARKER = word(12);

function claimSiblings(leafBody: string, ordinal: number, count: number): string[] {
  const commit = ethers.utils.keccak256(ethers.utils.hexConcat([RECORD, word(2), leafBody]));
  let layer = Array.from({ length: 1024 }, (_, index) => ethers.utils.keccak256(ethers.utils.hexConcat(
    index === ordinal
      ? [LEAF, MARKER, word(count), word(index), commit]
      : [EMPTY, MARKER, word(count), word(index)],
  )));
  const path: string[] = [];
  let index = ordinal;
  for (let level = 0; level < 10; level += 1) {
    path.push(layer[index ^ 1]);
    const parent = [];
    for (let i = 0; i < layer.length / 2; i += 1) {
      parent.push(ethers.utils.keccak256(ethers.utils.hexConcat([NODE, MARKER, word(level + 1), layer[2 * i], layer[2 * i + 1]])));
    }
    layer = parent;
    index >>= 1;
  }
  return path;
}

export async function registerWithdrawal(params: Withdrawal & { bridge: Contract; stateManager: Contract }) {
  const { bridge, stateManager, ...withdrawal } = params;
  const sent = await stateManager.applyBridgeWindow(...await buildBridgeWindow(stateManager, bridge, [withdrawal]));
  const receipt = await sent.wait();
  const parsed = receipt.logs.map((log: { topics: string[]; data: string }) => {
    try { return bridge.interface.parseLog(log); } catch { return undefined; }
  }).find((log: { name: string } | undefined) => log?.name === "InclusionAggregateRootPublished");
  const chainIndex = await stateManager.l1ChainIndex();
  const leaf = words([
    withdrawal.destinationChainIndex ?? chainIndex, withdrawal.senderUserId ?? 0,
    withdrawal.recipient, withdrawal.token, withdrawal.amount, withdrawal.nonce,
  ]);
  await bridge.claimAggregateWithdrawal(parsed.args.headerDigest, 0, leaf, claimSiblings(leaf, 0, 1));
  return word(withdrawal.nonce);
}
