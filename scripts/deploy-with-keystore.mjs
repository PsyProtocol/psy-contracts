#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { Wallet } from "ethers";

const contractsDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

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
    privateKey = Wallet.fromEncryptedJsonSync(
      readFileSync(path.resolve(contractsDir, keystorePath), "utf8"),
      walletPassword,
    ).privateKey;
    fromKeystore = true;
  } catch {
    fail("Failed to unlock deploy keystore.");
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
const child = spawnSync("npx", ["--no-install", "hardhat", ...args], {
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
