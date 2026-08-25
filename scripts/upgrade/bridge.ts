import fs from "fs";
import path from "path";
import type { BigNumber } from "ethers";
import { ethers } from "hardhat";

const UINT128_MAX = ethers.BigNumber.from(2).pow(128).sub(1);
const UINT32_MAX = ethers.BigNumber.from(2).pow(32).sub(1);
const AMOUNT_FIELDS = [
  "minDepositAmount",
  "depositCapacity",
  "depositRefillPerSecond",
  "custodyCap",
  "smallWithdrawalMax",
  "mediumWithdrawalMax",
] as const;
const DELAY_FIELDS = [
  "smallWithdrawalDelay",
  "mediumWithdrawalDelay",
  "largeWithdrawalDelay",
] as const;

export type FlowLimitConfig = Record<(typeof AMOUNT_FIELDS)[number] | (typeof DELAY_FIELDS)[number], string> & {
  configured: true;
};
type FlowLimitUintField = (typeof AMOUNT_FIELDS)[number] | (typeof DELAY_FIELDS)[number];

export type BridgeFlowLimitManifest = {
  tokens: string[];
  configs: FlowLimitConfig[];
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
  if (!Array.isArray(manifest.tokens) || !Array.isArray(manifest.configs) || manifest.tokens.length === 0) {
    throw new Error("Bridge flow-limit manifest must contain non-empty tokens and configs arrays");
  }
  if (manifest.tokens.length !== manifest.configs.length) {
    throw new Error("Bridge flow-limit manifest tokens/configs length mismatch");
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
    const expectedFields = new Set<string>([...AMOUNT_FIELDS, ...DELAY_FIELDS, "configured"]);
    for (const key of Object.keys(input)) {
      if (!expectedFields.has(key)) throw new Error(`configs[${index}] has unknown field ${key}`);
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
      || value("minDepositAmount").gt(value("depositCapacity"))
      || value("depositRefillPerSecond").isZero()
      || value("custodyCap").lt(value("minDepositAmount"))
      || value("smallWithdrawalMax").gte(value("mediumWithdrawalMax"))
      || value("smallWithdrawalDelay").gt(value("mediumWithdrawalDelay"))
      || value("mediumWithdrawalDelay").gt(value("largeWithdrawalDelay"))
    ) {
      throw new Error(`configs[${index}] violates Bridge TokenFlowConfig invariants`);
    }
    return output;
  });
  return { tokens, configs };
}

export function getTokenFlowConfigFromManifest(configPath: string, token: string): FlowLimitConfig {
  const manifest = loadBridgeFlowLimitManifest(configPath);
  const normalized = ethers.utils.getAddress(token);
  const index = manifest.tokens.findIndex((candidate) => candidate === normalized);
  if (index === -1) throw new Error(`token ${normalized} is not present in ${path.resolve(configPath)}`);
  return manifest.configs[index];
}

export async function getBridgeFlowLimitInitData(): Promise<string> {
  const configPath = process.env.BRIDGE_FLOW_LIMITS_FILE;
  if (!configPath) throw new Error("BRIDGE_FLOW_LIMITS_FILE is required for the atomic Bridge V3 upgrade");
  const manifest = loadBridgeFlowLimitManifest(configPath);
  const bridgeFactory = await ethers.getContractFactory("Bridge");
  return bridgeFactory.interface.encodeFunctionData("initializeFlowLimits", [
    manifest.tokens,
    manifest.configs,
  ]);
}

export async function upgradeBridge(executionTime?: string) {
  const { upgradeContract } = await import("./utils");
  const initData = await getBridgeFlowLimitInitData();
  return upgradeContract("Bridge", "Bridge", executionTime, initData);
}

if (require.main === module) {
  upgradeBridge(process.env.TIMELOCK_EXECUTION_TIME).catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
