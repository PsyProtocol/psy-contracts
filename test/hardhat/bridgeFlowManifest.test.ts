import { expect } from "chai";
import fs from "fs";
import os from "os";
import path from "path";
import { ethers } from "hardhat";
import {
  getTokenFlowConfigFromManifest,
  loadBridgeFlowLimitManifest,
} from "../../scripts/upgrade/bridge";
import { defaultFlowConfig } from "./helpers/deploySystem";

function stringConfig(overrides: Record<string, unknown> = {}) {
  return Object.fromEntries(
    Object.entries(defaultFlowConfig(overrides))
      .map(([key, value]) => [key, typeof value === "boolean" ? value : value.toString()]),
  );
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
    write({ tokens: [tokenA, tokenB], configs: [stringConfig(), stringConfig({ minDepositAmount: 2 })] });
    const manifest = loadBridgeFlowLimitManifest(file);
    expect(manifest.tokens).to.deep.equal([tokenA, tokenB]);
    expect(manifest.configs[1].minDepositAmount).to.equal("2");
    expect(() => getTokenFlowConfigFromManifest(file, ethers.Wallet.createRandom().address))
      .to.throw("is not present");
  });

  it("rejects malformed top-level arrays, count mismatch, duplicate tokens, and invalid addresses", function () {
    expectInvalid({}, "non-empty tokens and configs arrays");
    expectInvalid({ tokens: [tokenA], configs: [] }, "tokens/configs length mismatch");
    expectInvalid({ tokens: [tokenA, tokenA.toLowerCase()], configs: [stringConfig(), stringConfig()] }, "duplicate token");
    expectInvalid({ tokens: ["not-an-address"], configs: [stringConfig()] }, "invalid address");
  });

  it("rejects missing, extra, non-decimal, negative, and overflowing fields", function () {
    const missing = stringConfig();
    delete missing.minDepositAmount;
    expectInvalid({ tokens: [tokenA], configs: [missing] }, "minDepositAmount must be an unsigned decimal string");

    expectInvalid(
      { tokens: [tokenA], configs: [{ ...stringConfig(), surprise: "1" }] },
      "unknown field surprise",
    );
    for (const deletedField of ["maxDepositAmount", "withdrawalCapacity", "withdrawalRefillPerSecond"]) {
      expectInvalid(
        { tokens: [tokenA], configs: [{ ...stringConfig(), [deletedField]: "1" }] },
        `unknown field ${deletedField}`,
      );
    }
    expectInvalid(
      { tokens: [tokenA], configs: [{ ...stringConfig(), minDepositAmount: -1 }] },
      "must be an unsigned decimal string",
    );
    expectInvalid(
      { tokens: [tokenA], configs: [{ ...stringConfig(), minDepositAmount: "1.5" }] },
      "must be an unsigned decimal string",
    );
    expectInvalid(
      { tokens: [tokenA], configs: [{ ...stringConfig(), depositCapacity: (1n << 128n).toString() }] },
      "exceeds its Solidity integer width",
    );
    expectInvalid(
      { tokens: [tokenA], configs: [{ ...stringConfig(), largeWithdrawalDelay: (1n << 32n).toString() }] },
      "exceeds its Solidity integer width",
    );
  });

  it("rejects disabled and internally inconsistent token configs", function () {
    expectInvalid(
      { tokens: [tokenA], configs: [{ ...stringConfig(), configured: false }] },
      "configured must be true",
    );
    const invalidOverrides = [
      { minDepositAmount: 0 },
      { minDepositAmount: 2, depositCapacity: 1 },
      { depositRefillPerSecond: 0 },
      { minDepositAmount: 2, custodyCap: 1 },
      { smallWithdrawalMax: 10, mediumWithdrawalMax: 10 },
      { smallWithdrawalDelay: 2, mediumWithdrawalDelay: 1 },
      { mediumWithdrawalDelay: 2, largeWithdrawalDelay: 1 },
    ];
    for (const overrides of invalidOverrides) {
      expectInvalid(
        { tokens: [tokenA], configs: [stringConfig(overrides)] },
        "violates Bridge TokenFlowConfig invariants",
      );
    }
  });
});
