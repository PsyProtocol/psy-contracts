import { expect } from "chai";
import fs from "fs";
import os from "os";
import path from "path";
import { ethers } from "hardhat";
import {
  getTokenFlowConfigFromManifest,
  assertCompleteFlowTokenSet,
  loadBridgeFlowLimitManifest,
  tokenSetHash,
} from "../../scripts/upgrade/bridge";
import { defaultFlowConfig } from "./helpers/deploySystem";

function stringConfig(overrides: Record<string, unknown> = {}) {
  return Object.fromEntries(
    Object.entries(defaultFlowConfig(overrides))
      .map(([key, value]) => [key, typeof value === "boolean" ? value : value.toString()]),
  );
}

function manifest(tokens: string[], configs: Record<string, unknown>[], historicalWithdrawalTotals?: string[]) {
  return {
    tokens,
    configs,
    historicalWithdrawalTotals: historicalWithdrawalTotals ?? tokens.map(() => "0"),
  };
}

describe("Bridge flow-limit manifest validation", function () {
  let dir: string;
  let file: string;
  const tokenA = ethers.Wallet.createRandom().address;
  const tokenB = ethers.Wallet.createRandom().address;

  beforeEach(function () {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "psy-manifest-validation-"));
    file = path.join(dir, "manifest.json");
  });

  afterEach(function () {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  function write(value: unknown): void {
    fs.writeFileSync(file, JSON.stringify(value));
  }

  function expectInvalid(value: unknown, message: string): void {
    write(value);
    expect(() => loadBridgeFlowLimitManifest(file)).to.throw(message);
  }

  it("loads complete per-token configs and rejects a token omitted from the manifest", function () {
    write(manifest([tokenA, tokenB], [stringConfig(), stringConfig({ minDepositAmount: 2 })], ["7", "9"]));
    const loaded = loadBridgeFlowLimitManifest(file);
    expect(loaded.tokens).to.deep.equal([tokenA, tokenB]);
    expect(loaded.configs[1].minDepositAmount).to.equal("2");
    expect(loaded.historicalWithdrawalTotals).to.deep.equal(["7", "9"]);
    expect(() => getTokenFlowConfigFromManifest(file, ethers.Wallet.createRandom().address))
      .to.throw("is not present");
  });

  it("rejects an upgrade manifest subset before calldata encoding and accepts the complete set", function () {
    expect(() => assertCompleteFlowTokenSet([tokenA], [tokenA, tokenB]))
      .to.throw("does not match the governance flow-token set");
    expect(() => assertCompleteFlowTokenSet([tokenB, tokenA], [tokenA, tokenB])).not.to.throw();
    expect(tokenSetHash([tokenB, tokenA])).to.equal(tokenSetHash([tokenA, tokenB]));
  });

  it("rejects malformed top-level arrays, count mismatch, duplicate tokens, and invalid addresses", function () {
    expectInvalid({}, "non-empty tokens, configs, and historicalWithdrawalTotals arrays");
    expectInvalid(manifest([tokenA], []), "array length mismatch");
    expectInvalid(manifest([tokenA, tokenA.toLowerCase()], [stringConfig(), stringConfig()]), "duplicate token");
    expectInvalid(manifest(["not-an-address"], [stringConfig()]), "invalid address");
    expectInvalid({ ...manifest([tokenA], [stringConfig()]), surprise: [] }, "unknown field surprise");
    expectInvalid(
      { tokens: [tokenA], configs: [stringConfig()] },
      "non-empty tokens, configs, and historicalWithdrawalTotals arrays",
    );
    expectInvalid(manifest([tokenA], [stringConfig()], []), "array length mismatch");
  });

  it("rejects missing, extra, non-decimal, negative, and overflowing fields", function () {
    const missing = stringConfig();
    delete missing.minDepositAmount;
    expectInvalid(manifest([tokenA], [missing]), "minDepositAmount must be an unsigned decimal string");

    expectInvalid(
      manifest([tokenA], [{ ...stringConfig(), surprise: "1" }]),
      "unknown field surprise",
    );
    for (const deletedField of ["depositBucketCapacity", "depositRefillPerSecond", "custodyCap", "lifetimeWithdrawalThreshold", "thresholdExceededWithdrawalDelay"]) {
      expectInvalid(
        manifest([tokenA], [{ ...stringConfig(), [deletedField]: "1" }]),
        `unknown field ${deletedField}`,
      );
    }
    expectInvalid(
      manifest([tokenA], [{ ...stringConfig(), minDepositAmount: -1 }]),
      "must be an unsigned decimal string",
    );
    expectInvalid(
      manifest([tokenA], [{ ...stringConfig(), minDepositAmount: "1.5" }]),
      "must be an unsigned decimal string",
    );
    expectInvalid(
      manifest([tokenA], [{ ...stringConfig(), depositCap: (1n << 128n).toString() }]),
      "exceeds its Solidity integer width",
    );
    expectInvalid(
      manifest([tokenA], [{ ...stringConfig(), largeWithdrawalDelay: (1n << 32n).toString() }]),
      "exceeds its Solidity integer width",
    );
    const missingWithdrawalCap = stringConfig();
    delete missingWithdrawalCap.totalWithdrawalCap;
    expectInvalid(
      manifest([tokenA], [missingWithdrawalCap]),
      "totalWithdrawalCap must be an unsigned decimal string",
    );
    expectInvalid(
      manifest([tokenA], [stringConfig({ totalWithdrawalCap: (1n << 128n).toString() })]),
      "exceeds its Solidity integer width",
    );
    expectInvalid(manifest([tokenA], [stringConfig()], ["-1"]), "must be an unsigned decimal string");
    expectInvalid(
      manifest([tokenA], [stringConfig()], [(1n << 256n).toString()]),
      "exceeds its Solidity integer width",
    );
  });

  it("rejects disabled and internally inconsistent token configs", function () {
    expectInvalid(
      manifest([tokenA], [{ ...stringConfig(), configured: false }]),
      "configured must be true",
    );
    const invalidOverrides = [
      { minDepositAmount: 0 },
      { minDepositAmount: 2, depositCap: 1 },
      { smallWithdrawalMax: 2, mediumWithdrawalMax: 1 },
      { smallWithdrawalDelay: 2, mediumWithdrawalDelay: 1 },
      { mediumWithdrawalDelay: 2, largeWithdrawalDelay: 1 },
    ];
    for (const overrides of invalidOverrides) {
      expectInvalid(
        manifest([tokenA], [stringConfig(overrides)]),
        "violates Bridge TokenFlowConfig invariants",
      );
    }
  });
});
