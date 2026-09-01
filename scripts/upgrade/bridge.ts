import fs from "fs";
import path from "path";
import type { BigNumber } from "ethers";
import { deployments, ethers, network } from "hardhat";

const UINT128_MAX = ethers.BigNumber.from(2).pow(128).sub(1);
const UINT32_MAX = ethers.BigNumber.from(2).pow(32).sub(1);
const UINT256_MAX = ethers.constants.MaxUint256;

export function canonicalTokenSet(tokens: string[]): string[] {
  return tokens.map((token) => ethers.utils.getAddress(token)).sort((a, b) => {
    const left = BigInt(a.toLowerCase());
    const right = BigInt(b.toLowerCase());
    return left < right ? -1 : left > right ? 1 : 0;
  });
}

export function tokenSetHash(tokens: string[]): string {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["address[]"], [canonicalTokenSet(tokens)]),
  );
}

export function assertCompleteV3FlowTokenSet(tokens: string[], authoritativeTokens: string[]): void {
  const actual = canonicalTokenSet(tokens);
  const expected = canonicalTokenSet(authoritativeTokens);
  if (actual.length !== expected.length || actual.some((token, index) => token !== expected[index])) {
    throw new Error(
      `Bridge V4 token inventory does not match authoritative V3 flow-token set: expected ${expected.join(",")}; received ${actual.join(",")}`,
    );
  }
}

function loadAuthoritativeV3FlowTokens(): string[] {
  const raw = process.env.BRIDGE_V3_FLOW_TOKENS;
  if (!raw) {
    throw new Error("BRIDGE_V3_FLOW_TOKENS is required for the Bridge V4 migration");
  }
  const parsed = JSON.parse(raw) as unknown;
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.some((token) => typeof token !== "string")) {
    throw new Error("BRIDGE_V3_FLOW_TOKENS must be a non-empty JSON address array");
  }
  return parsed as string[];
}
const AMOUNT_FIELDS = [
  "minDepositAmount",
  "depositBucketCapacity",
  "depositRefillPerSecond",
  "custodyCap",
  "smallWithdrawalMax",
  "lifetimeWithdrawalThreshold",
] as const;
const DELAY_FIELDS = [
  "smallWithdrawalDelay",
  "mediumWithdrawalDelay",
  "thresholdExceededWithdrawalDelay",
] as const;
const CONFIG_FIELDS: Record<string, true> = Object.fromEntries(
  [...AMOUNT_FIELDS, ...DELAY_FIELDS, "configured"].map((field) => [field, true]),
);

export type FlowLimitConfig = Record<(typeof AMOUNT_FIELDS)[number] | (typeof DELAY_FIELDS)[number], string> & {
  configured: true;
};
type FlowLimitUintField = (typeof AMOUNT_FIELDS)[number] | (typeof DELAY_FIELDS)[number];

export type BridgeFlowLimitManifest = {
  tokens: string[];
  configs: FlowLimitConfig[];
  historicalWithdrawalTotals: string[];
};

function parseUint(value: unknown, field: string, max: BigNumber): string {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]*)$/.test(value)) {
    throw new Error(`${field} must be an unsigned decimal string`);
  }
  const parsed = ethers.BigNumber.from(value);
  if (parsed.gt(max)) throw new Error(`${field} exceeds its Solidity integer width`);
  return parsed.toString();
}

export function loadBridgeFlowLimitManifest(configPath: string): BridgeFlowLimitManifest {
  const absolutePath = path.resolve(configPath);
  const manifest = JSON.parse(fs.readFileSync(absolutePath, "utf8")) as Record<string, unknown>;
  const topLevelFields: Record<string, true> = {
    tokens: true,
    configs: true,
    historicalWithdrawalTotals: true,
  };
  for (const key of Object.keys(manifest)) {
    if (!topLevelFields[key]) throw new Error(`Bridge flow-limit manifest has unknown field ${key}`);
  }
  if (
    !Array.isArray(manifest.tokens)
    || !Array.isArray(manifest.configs)
    || !Array.isArray(manifest.historicalWithdrawalTotals)
    || manifest.tokens.length === 0
  ) {
    throw new Error(
      "Bridge flow-limit manifest must contain non-empty tokens, configs, and historicalWithdrawalTotals arrays",
    );
  }
  if (
    manifest.tokens.length !== manifest.configs.length
    || manifest.tokens.length !== manifest.historicalWithdrawalTotals.length
  ) {
    throw new Error("Bridge flow-limit manifest array length mismatch");
  }
  const seen = new Set<string>();
  const tokens = manifest.tokens.map((token, index) => {
    if (typeof token !== "string") throw new Error(`tokens[${index}] must be an address string`);
    const normalized = ethers.utils.getAddress(token);
    if (seen.has(normalized)) throw new Error(`duplicate token ${normalized}`);
    seen.add(normalized);
    return normalized;
  });
  const configs = manifest.configs.map((raw, index) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error(`configs[${index}] must be an object`);
    }
    const input = raw as Record<string, unknown>;
    for (const key of Object.keys(input)) {
      if (!CONFIG_FIELDS[key]) throw new Error(`configs[${index}] has unknown field ${key}`);
    }
    if (input.configured !== true) throw new Error(`configs[${index}].configured must be true`);
    const output = { configured: true } as FlowLimitConfig;
    for (const field of AMOUNT_FIELDS) {
      output[field] = parseUint(input[field], `configs[${index}].${field}`, UINT128_MAX);
    }
    for (const field of DELAY_FIELDS) {
      output[field] = parseUint(input[field], `configs[${index}].${field}`, UINT32_MAX);
    }
    const value = (field: FlowLimitUintField) => ethers.BigNumber.from(output[field]);
    if (
      value("minDepositAmount").isZero()
      || value("minDepositAmount").gt(value("depositBucketCapacity"))
      || value("depositRefillPerSecond").isZero()
      || value("custodyCap").lt(value("minDepositAmount"))
      || value("smallWithdrawalDelay").gt(value("mediumWithdrawalDelay"))
      || value("mediumWithdrawalDelay").gt(value("thresholdExceededWithdrawalDelay"))
    ) {
      throw new Error(`configs[${index}] violates Bridge TokenFlowConfig invariants`);
    }
    return output;
  });
  const historicalWithdrawalTotals = manifest.historicalWithdrawalTotals.map((raw, index) =>
    parseUint(raw, `historicalWithdrawalTotals[${index}]`, UINT256_MAX)
  );
  return { tokens, configs, historicalWithdrawalTotals };
}

export function getTokenFlowConfigFromManifest(configPath: string, token: string): FlowLimitConfig {
  const manifest = loadBridgeFlowLimitManifest(configPath);
  const normalized = ethers.utils.getAddress(token);
  const index = manifest.tokens.findIndex((candidate) => candidate === normalized);
  if (index === -1) throw new Error(`token ${normalized} is not present in ${path.resolve(configPath)}`);
  return manifest.configs[index];
}

export async function getBridgeWithdrawalTotalsInitData(): Promise<string> {
  const configPath = process.env.BRIDGE_FLOW_LIMITS_FILE;
  if (!configPath) throw new Error("BRIDGE_FLOW_LIMITS_FILE is required for the atomic Bridge V4 upgrade");
  const manifest = loadBridgeFlowLimitManifest(configPath);
  assertCompleteV3FlowTokenSet(manifest.tokens, loadAuthoritativeV3FlowTokens());
  const bridgeDeployment = await deployments.get("Bridge");
  const bridge = await ethers.getContractAt("Bridge", bridgeDeployment.address);
  for (const token of manifest.tokens) {
    const config = await bridge.getTokenFlowConfig(token);
    if (!config.configured) throw new Error(`Bridge token ${token} is not configured on-chain`);
  }
  const timelock = await deployments.get("ExecutorWithTimelock");
  const bridgeFactory = await ethers.getContractFactory("Bridge");
  return bridgeFactory.interface.encodeFunctionData("initializeWithdrawalTotals", [
    manifest.tokens,
    manifest.historicalWithdrawalTotals,
    tokenSetHash(manifest.tokens),
    timelock.address,
  ]);
}

export async function upgradeBridge(executionTime?: string) {
  const { upgradeContract } = await import("./utils");
  const initData = await getBridgeWithdrawalTotalsInitData();
  return upgradeContract("Bridge", "Bridge", executionTime, initData);
}

if (require.main === module) {
  upgradeBridge(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
