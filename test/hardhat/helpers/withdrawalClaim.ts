import { ethers } from "hardhat";

const WITHDRAWAL_BATCH_SLOT_WORDS = 35;
const WITHDRAWAL_BATCH_SLOT_COUNT = 32;

// Router id per L1 token, as bound by mapClaimToken: slot word 34.
const slotTokenIds = new Map<string, number>();
// Keccak claim identity of the most recently built slot for each raw nonce.
const leafIds = new Map<bigint, string>();

beforeEach(() => leafIds.clear());

export async function mapClaimToken(router: any, token: string, id: number): Promise<void> {
  await router.setTokenMapping(token, ethers.utils.hexZeroPad(ethers.utils.hexlify(id), 32));
  slotTokenIds.set(token.toLowerCase(), id);
}

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

/// The V6 identity recomputed the way the runtime does it (relayer
/// withdrawal_claim_identity_words): keccak over the 35 slot words, each
/// big-endian u32, 140 bytes.
function slotLeafId(slotData: bigint[], slot: number): string {
  const words = slotData.slice(slot * WITHDRAWAL_BATCH_SLOT_WORDS, (slot + 1) * WITHDRAWAL_BATCH_SLOT_WORDS);
  return ethers.utils.keccak256(ethers.utils.solidityPack(words.map(() => "uint32"), words.map((word) => word.toString())));
}

function slotNonce(slotData: bigint[], slot: number): bigint {
  const base = slot * WITHDRAWAL_BATCH_SLOT_WORDS + 25;
  return slotData.slice(base, base + 8).reduce((acc, word) => (acc << 32n) | word, 0n);
}

function recordLeafIds(publicInputs: bigint[], slotData: bigint[]): void {
  for (let slot = 0; slot < Number(publicInputs[8]); slot++) {
    leafIds.set(slotNonce(slotData, slot), slotLeafId(slotData, slot));
  }
}

/// Throws for an unbuilt nonce so no assertion silently reads a wrong key.
export function withdrawalLeafIdOf(nonce: bigint): string {
  const id = leafIds.get(nonce);
  if (id === undefined) throw new Error(`no slot built for nonce ${nonce}`);
  return id;
}

export interface WithdrawalBatchClaimItem {
  senderUserId?: number;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destinationChainIndex: number;
  tokenContractId?: number;
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
    slotData[offset + 34] = BigInt(item.tokenContractId ?? slotTokenIds.get(item.token.toLowerCase()) ?? 0);
  });
  setWords(publicInputs, 10, bytes32ToU32x8(batchSlotDataCommit(slotData)));
  recordLeafIds(publicInputs, slotData);
  return { publicInputs, slotData };
}

export function patchBatchCommit(publicInputs: bigint[], slotData: bigint[]): void {
  const commitWords = bytes32ToU32x8(batchSlotDataCommit(slotData));
  for (let index = 0; index < 8; index++) {
    publicInputs[10 + index] = commitWords[index];
  }
  recordLeafIds(publicInputs, slotData);
}

export function buildWithdrawalBatchClaimSingle(params: {
  withdrawalRoot: string;
  recipient: string;
  token: string;
  amount: bigint;
  nonce: bigint;
  destinationChainIndex: number;
  tokenContractId?: number;
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
        tokenContractId: params.tokenContractId,
      },
    ],
  });
}
