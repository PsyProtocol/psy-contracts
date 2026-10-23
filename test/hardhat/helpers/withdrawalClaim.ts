import { ethers } from "hardhat";

const WITHDRAWAL_BATCH_SLOT_WORDS = 34;
const WITHDRAWAL_BATCH_SLOT_COUNT = 32;

function bytes32ToU32x8(value: string): bigint[] {
  const bytes = ethers.utils.arrayify(ethers.utils.hexZeroPad(value, 32));
  const words: bigint[] = [];
  for (let index = 0; index < 8; index++) {
    const offset = index * 4;
    const word =
      (BigInt(bytes[offset]) << 24n) |
      (BigInt(bytes[offset + 1]) << 16n) |
      (BigInt(bytes[offset + 2]) << 8n) |
      BigInt(bytes[offset + 3]);
    words.push(word);
  }
  return words;
}

function batchSlotDataCommit(slotData: bigint[]): string {
  const bytes: number[] = [];
  for (const word of slotData) {
    const normalized = Number(word & 0xffff_ffffn);
    bytes.push(
      (normalized >>> 24) & 0xff,
      (normalized >>> 16) & 0xff,
      (normalized >>> 8) & 0xff,
      normalized & 0xff,
    );
  }
  return ethers.utils.keccak256(Uint8Array.from(bytes));
}

export interface WithdrawalBatchClaimItem {
  senderUserId?: number;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destinationChainIndex: number;
}

export function buildWithdrawalBatchClaim(params: {
  withdrawalRoot: string;
  items: WithdrawalBatchClaimItem[];
  bridgeUserId?: number;
}): { publicInputs: bigint[]; slotData: bigint[] } {
  const publicInputs = new Array<bigint>(18).fill(0n);
  const slotData = new Array<bigint>(
    WITHDRAWAL_BATCH_SLOT_WORDS * WITHDRAWAL_BATCH_SLOT_COUNT,
  ).fill(0n);
  const setWords = (target: bigint[], offset: number, words: bigint[]) => {
    for (let index = 0; index < words.length; index++) {
      target[offset + index] = words[index];
    }
  };

  setWords(publicInputs, 0, bytes32ToU32x8(params.withdrawalRoot));
  publicInputs[8] = BigInt(params.items.length);
  publicInputs[9] = BigInt(params.bridgeUserId ?? 524288);
  params.items.forEach((item, slot) => {
    const offset = slot * WITHDRAWAL_BATCH_SLOT_WORDS;
    slotData[offset] = BigInt(item.senderUserId ?? 0);
    setWords(slotData, offset + 1, bytes32ToU32x8(ethers.utils.hexZeroPad(item.recipient, 32)));
    setWords(slotData, offset + 9, bytes32ToU32x8(ethers.utils.hexZeroPad(item.token, 32)));
    setWords(slotData, offset + 17, bytes32ToU32x8(ethers.utils.hexZeroPad(`0x${item.amount.toString(16)}`, 32)));
    setWords(slotData, offset + 25, bytes32ToU32x8(ethers.utils.hexZeroPad(`0x${item.nonce.toString(16)}`, 32)));
    slotData[offset + 33] = BigInt(item.destinationChainIndex);
  });
  setWords(publicInputs, 10, bytes32ToU32x8(batchSlotDataCommit(slotData)));
  return { publicInputs, slotData };
}

export function patchBatchCommit(publicInputs: bigint[], slotData: bigint[]): void {
  const commitWords = bytes32ToU32x8(batchSlotDataCommit(slotData));
  for (let index = 0; index < 8; index++) {
    publicInputs[10 + index] = commitWords[index];
  }
}

export function buildWithdrawalBatchClaimSingle(params: {
  withdrawalRoot: string;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destinationChainIndex: number;
  senderUserId?: number;
  bridgeUserId?: number;
}): { publicInputs: bigint[]; slotData: bigint[] } {
  return buildWithdrawalBatchClaim({
    withdrawalRoot: params.withdrawalRoot,
    bridgeUserId: params.bridgeUserId,
    items: [
      {
        senderUserId: params.senderUserId,
        recipient: params.recipient,
        token: params.token,
        amount: params.amount,
        nonce: params.nonce,
        destinationChainIndex: params.destinationChainIndex,
      },
    ],
  });
}
