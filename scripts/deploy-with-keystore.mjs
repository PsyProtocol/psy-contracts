#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import path from "node:path";
import process from "node:process";

const contractsDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

function fail(message) {
  console.error(message);
  process.exit(1);
}

const keystorePath = process.env.KEYSTORE_PATH;
const walletPassword = process.env.WALLET_PASSWORD;
const directPrivateKey = process.env.PRIVATE_KEY || process.env.PSY_RELAYER_PRIVKEY;

let privateKey;
let fromKeystore = false;

if (directPrivateKey) {
  privateKey = directPrivateKey.trim();
} else {
  if (!keystorePath) {
    fail("Missing KEYSTORE_PATH or PRIVATE_KEY.");
  }
  if (!walletPassword) {
    fail("Missing WALLET_PASSWORD.");
  }
  try {
    privateKey = execFileSync(
      "cast",
      ["wallet", "private-key", "--keystore", keystorePath, "--password", walletPassword],
      {
        cwd: contractsDir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      },
    ).trim();
    fromKeystore = true;
  } catch (error) {
    const stderr = error instanceof Error && "stderr" in error ? String(error.stderr || "") : "";
    fail(`Failed to unlock deploy keystore: ${stderr.trim() || String(error)}`);
  }
}

const env = {
  ...process.env,
  PSY_INTERNAL_DEPLOY_PRIVATE_KEY: privateKey,
};
if (fromKeystore) {
  env.PSY_INTERNAL_DEPLOY_FROM_KEYSTORE = "1";
} else {
  delete env.PSY_INTERNAL_DEPLOY_FROM_KEYSTORE;
}
delete env.PRIVATE_KEY;
delete env.PSY_RELAYER_PRIVKEY;

const args = process.argv.slice(2);
const child = spawnSync("npx", ["hardhat", ...args], {
  cwd: contractsDir,
  env,
  stdio: "inherit",
});

delete env.PSY_INTERNAL_DEPLOY_PRIVATE_KEY;
delete env.PSY_INTERNAL_DEPLOY_FROM_KEYSTORE;
privateKey = "";

if (child.error) {
  fail(`Failed to start hardhat: ${child.error.message}`);
}

process.exit(child.status ?? 1);
