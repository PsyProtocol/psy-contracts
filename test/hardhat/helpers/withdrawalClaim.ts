import { ethers } from "hardhat";
import type { BigNumberish, Contract } from "ethers";

// Nonzero mock proofs exercise orchestration only, never cryptographic acceptance.
export const ORCHESTRATION_PROOF = [1n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];
export const ZERO_PROOF = new Array<bigint>(8).fill(0n);
export const word = (value: BigNumberish): string => ethers.utils.hexZeroPad(ethers.BigNumber.from(value).toHexString(), 32);
const words = (values: BigNumberish[]): string => ethers.utils.hexConcat(values.map(word));
const rootWords = (root: string): bigint[] => [192n, 128n, 64n, 0n].map(shift => (BigInt(root) >> shift) & ((1n << 64n) - 1n));

const OPENING_VERSION = 4n;
const OPENING_DOMAIN = ethers.utils.id("PsyBridge/Opening/4");

// openingDigest is not an opening field: it binds the domain tag to the exact encoded bytes.
export function openingDigest(opening: string): string {
  return ethers.utils.keccak256(ethers.utils.hexConcat([OPENING_DOMAIN, opening]));
}

export function buildNetworkConfig(chainId: number, bridge: string, stateManager: string, rewardPayer: string, rewardToken: string): string {
  return words([1, 0, 524288, 7, 1, 0, chainId, bridge, stateManager, 0, 0, 0, 0, 0,
    0, rewardPayer, rewardToken, 1, 18, 1024, 1024]);
}

export type Withdrawal = {
  recipient: string;
  tokenContractId: number;
  amount: bigint;
  nonce: bigint;
  destinationChainIndex?: number;
  senderUserId?: number;
};

// Mirrors Bridge's scoped record key: keccak256(abi.encode(uint32 senderUserId, uint32 tokenContractId, bytes32 nonce)).
export function scopedKey(senderUserId: number, tokenContractId: number, nonce: BigNumberish): string {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["uint32", "uint32", "bytes32"], [senderUserId, tokenContractId, word(nonce)]),
  );
}

export type BridgeOpeningCall = [bigint[], string];

export async function buildBridgeOpeningCall(stateManager: Contract, bridge: Contract, withdrawals: Withdrawal[] = [], endCheckpointId?: bigint): Promise<BridgeOpeningCall> {
  const startId = BigInt((await stateManager.lastFinalizedCheckpointId()).toString());
  const startRoot = await stateManager.lastVerifiedCheckpointRoot();
  const endId = endCheckpointId ?? startId + 1n;
  const endRoot = endId === startId ? startRoot : word(endId);
  const chainIndex = BigInt((await stateManager.l1ChainIndex()).toString());
  const configHash = await stateManager.configHash();
  const depositRoot = await bridge.depositRoot();
  const depositCount = await bridge.provedDepositCount();
  const opening = ethers.utils.hexConcat([
    // Header: version, configHash, endCheckpointId, endCheckpointRoot, endUserRoot, C, D, Rw, Rr.
    words([OPENING_VERSION, configHash, endId]),
    words(rootWords(endRoot)),
    words(rootWords(ethers.constants.HashZero)),
    words([1, 0, withdrawals.length, 0]),
    // Single local chain row: chain, startId, startRoot, oldDepositRoot, newDepositRoot, oldCount, newCount.
    words([chainIndex, startId]),
    words(rootWords(startRoot)),
    words(rootWords(depositRoot)),
    words(rootWords(depositRoot)),
    words([depositCount, depositCount]),
    // Withdrawal records: kind, destinationChain, userId, tokenContractId, nonce, three reserved words, recipient, amount.
    ...withdrawals.map(leaf => words([
      1, leaf.destinationChainIndex ?? chainIndex, leaf.senderUserId ?? 0, leaf.tokenContractId, leaf.nonce, 0, 0, 0,
      leaf.recipient, leaf.amount,
    ])),
  ]);
  return [ORCHESTRATION_PROOF, opening];
}

const TOKEN_MAP_BASE = 0;
const TOKEN_MAP_CAPACITY = 1024;
const TOKEN_MAP_HEIGHT = 32;

// Binds a mock token to a contract id. The fixture verifier stores exactly Bridge's policy
// preimage, so the install-time and per-record hash rechecks pass in the mock world only.
export async function installWithdrawalToken(bridge: Contract, verifier: Contract, stateManager: Contract, token: string, tokenContractId: number) {
  const chainIndex = Number((await stateManager.l1ChainIndex()).toString());
  const approvedContractLeaf = word(tokenContractId);
  await verifier.setWithdrawalTokenPolicy(
    chainIndex, tokenContractId, token, approvedContractLeaf, TOKEN_MAP_BASE, TOKEN_MAP_CAPACITY, TOKEN_MAP_HEIGHT,
  );
  await bridge.installWithdrawalToken(tokenContractId, token, approvedContractLeaf, TOKEN_MAP_BASE, TOKEN_MAP_CAPACITY, TOKEN_MAP_HEIGHT);
}

export async function registerWithdrawal(params: Withdrawal & { bridge: Contract; stateManager: Contract }) {
  const { bridge, stateManager, ...withdrawal } = params;
  const senderUserId = withdrawal.senderUserId ?? 0;
  const sent = await stateManager.applyBridgeOpening(...await buildBridgeOpeningCall(stateManager, bridge, [withdrawal]));
  await sent.wait();
  const nonce = word(withdrawal.nonce);
  return { key: scopedKey(senderUserId, withdrawal.tokenContractId, nonce), senderUserId, tokenContractId: withdrawal.tokenContractId, nonce };
}
