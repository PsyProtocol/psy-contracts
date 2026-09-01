import fs from "fs";
import { BigNumber, ethers as ethersLibrary } from "ethers";

const timelockInterface = new ethersLibrary.utils.Interface([
  "function queueTransaction(address target,uint256 value,string signature,bytes data,uint256 executionTime,bool withDelegatecall)",
  "function executeTransaction(address target,uint256 value,string signature,bytes data,uint256 executionTime,bool withDelegatecall)",
  "function cancelTransaction(address target,uint256 value,string signature,bytes data,uint256 executionTime,bool withDelegatecall)",
]);

const protocolInterface = new ethersLibrary.utils.Interface([
  "function setTokenFlowConfig(address token,(uint128 minDepositAmount,uint128 depositCap,uint128 smallWithdrawalMax,uint128 mediumWithdrawalMax,uint128 totalWithdrawalCap,uint32 smallWithdrawalDelay,uint32 mediumWithdrawalDelay,uint32 largeWithdrawalDelay,bool configured) next,bytes32 expectedConfigHash)",
  "function forceClaimWithdrawal(bytes32 nonce)",
  "function setGlobalPauseFlags(uint8 flags)",
  "function setTokenPauseFlags(address token,uint8 flags)",
  "function rescueERC20(address token,address to,uint256 amount)",
  "function rescueNative(address to,uint256 amount)",
  "function rescueWETHAsNative(address to,uint256 amount)",
  "function upgrade(address proxy,address implementation)",
  "function upgradeAndCall(address proxy,address implementation,bytes data)",
  "function grantRole(bytes32 role,address account)",
  "function revokeRole(bytes32 role,address account)",
  "function transferOwnership(address newOwner)",
  "function setPendingAdmin(address newPendingAdmin)",
  "function acceptAdmin()",
  "function initializeFlowLimits(address[] tokens,(uint128 minDepositAmount,uint128 depositCap,uint128 smallWithdrawalMax,uint128 mediumWithdrawalMax,uint128 totalWithdrawalCap,uint32 smallWithdrawalDelay,uint32 mediumWithdrawalDelay,uint32 largeWithdrawalDelay,bool configured)[] configs)",
  "function initializeWithdrawalTotals(address[] configuredTokens,(uint128 minDepositAmount,uint128 depositCap,uint128 smallWithdrawalMax,uint128 mediumWithdrawalMax,uint128 totalWithdrawalCap,uint32 smallWithdrawalDelay,uint32 mediumWithdrawalDelay,uint32 largeWithdrawalDelay,bool configured)[] configs,uint256[] historicalTotals,bytes32 expectedTokenSetHash,address forceClaimExecutor)",
]);

export type DecodedTransaction = {
  target: string;
  value: string;
  selector: string;
  functionName: string | null;
  signature: string | null;
  arguments: unknown[];
  actionHash?: string;
  inner?: DecodedTransaction;
};

function jsonValue(value: unknown): unknown {
  if (BigNumber.isBigNumber(value)) return value.toString();
  if (Array.isArray(value)) return value.map(jsonValue);
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([key]) => !/^\d+$/.test(key))
      .map(([key, child]) => [key, jsonValue(child)]);
    return entries.length === 0 ? value : Object.fromEntries(entries);
  }
  return value;
}

function parseKnown(data: string) {
  for (const iface of [timelockInterface, protocolInterface]) {
    try {
      return iface.parseTransaction({ data });
    } catch {
      // Try the next known governance interface.
    }
  }
  return null;
}

export function decodeGovernanceTransaction(target: string, data: string, value = "0"): DecodedTransaction {
  const normalizedTarget = ethersLibrary.utils.getAddress(target);
  if (!ethersLibrary.utils.isHexString(data) || data.length < 10) throw new Error("data must contain a 4-byte selector");
  const parsed = parseKnown(data);
  const decoded: DecodedTransaction = {
    target: normalizedTarget,
    value: BigNumber.from(value).toString(),
    selector: data.slice(0, 10),
    functionName: parsed?.name ?? null,
    signature: parsed?.signature ?? null,
    arguments: parsed ? Array.from(parsed.args).map(jsonValue) : [],
  };
  if (parsed && ["queueTransaction", "executeTransaction", "cancelTransaction"].includes(parsed.name)) {
    const [innerTarget, innerValue, callSignature, innerData, executionTime, withDelegatecall] = parsed.args;
    const action = [innerTarget, innerValue, callSignature, innerData, executionTime, withDelegatecall];
    decoded.actionHash = ethersLibrary.utils.keccak256(
      ethersLibrary.utils.defaultAbiCoder.encode(
        ["address", "uint256", "string", "bytes", "uint256", "bool"],
        action,
      ),
    );
    const effectiveInnerData = callSignature.length === 0
      ? innerData
      : ethersLibrary.utils.hexConcat([
        ethersLibrary.utils.id(callSignature).slice(0, 10),
        innerData,
      ]);
    decoded.inner = decodeGovernanceTransaction(innerTarget, effectiveInnerData, innerValue.toString());
  } else if (parsed?.name === "upgradeAndCall" && parsed.args[2] !== "0x") {
    decoded.inner = decodeGovernanceTransaction(parsed.args[0], parsed.args[2]);
  }
  return decoded;
}

export function decodeSafeProposalFile(file: string): DecodedTransaction[] {
  const payload = JSON.parse(fs.readFileSync(file, "utf8")) as { transactions?: unknown };
  if (!Array.isArray(payload.transactions) || payload.transactions.length === 0) {
    throw new Error("Safe proposal must contain a non-empty transactions array");
  }
  return payload.transactions.map((raw, index) => {
    if (!raw || typeof raw !== "object") throw new Error(`transactions[${index}] must be an object`);
    const tx = raw as Record<string, unknown>;
    if (typeof tx.to !== "string" || typeof tx.data !== "string") {
      throw new Error(`transactions[${index}] must contain string to and data fields`);
    }
    return decodeGovernanceTransaction(tx.to, tx.data, typeof tx.value === "string" ? tx.value : "0");
  });
}
