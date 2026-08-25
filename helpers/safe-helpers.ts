import { promises as fsp } from "fs";
import path from "path";
import { ethers, network } from "hardhat";
import { MULTI_SIG, SAFE_TX_SERVICE_URL } from "./hardhat-constants";

export type MetaTransaction = {
  to: string;
  value?: string;
  data: string;
};

export function buildSafeTransactionBuilderPayload(params: {
  safe: string;
  proposer: string;
  chainId: string;
  networkName: string;
  serviceUrl?: string;
  transactions: MetaTransaction[];
  createdAt?: number;
}) {
  return {
    version: "1.0",
    chainId: params.chainId,
    createdAt: params.createdAt ?? Date.now(),
    meta: {
      name: `Psy governance (${params.networkName})`,
      description: params.serviceUrl ? `Transaction service: ${params.serviceUrl}` : "Psy governance operation",
      txBuilderVersion: "1.18.0",
      createdFromSafeAddress: ethers.utils.getAddress(params.safe),
      createdFromOwnerAddress: ethers.utils.getAddress(params.proposer),
    },
    transactions: params.transactions.map((tx) => ({
      to: ethers.utils.getAddress(tx.to),
      value: tx.value ?? "0",
      data: tx.data,
      contractMethod: null,
      contractInputsValues: null,
    })),
  };
}

async function writeSafeProposal(payload: unknown): Promise<void> {
  const dir = path.join(process.cwd(), "deployments", network.name, "safe-proposals");
  await fsp.mkdir(dir, { recursive: true });
  const file = path.join(dir, `${Date.now()}.json`);
  await fsp.writeFile(file, JSON.stringify(payload, null, 2) + "\n", "utf8");
  console.log(`wrote Safe proposal payload: ${file}`);
}

/// Offline Safe payload writer. The repo intentionally avoids Safe SDK dependencies; operators
/// can submit the emitted target/data through the Safe UI or a separate signer environment.
export async function proposeSafeTransaction(target: string, data: string): Promise<void> {
  if (!MULTI_SIG) throw new Error("MULTI_SIG is required for DRY_RUN=Safe");
  const [signer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  const proposer = await signer.getAddress();
  await writeSafeProposal(buildSafeTransactionBuilderPayload({
    safe: MULTI_SIG,
    proposer,
    chainId: chainId.toString(),
    networkName: network.name,
    serviceUrl: SAFE_TX_SERVICE_URL,
    transactions: [{ to: target, value: "0", data }],
  }));
}

export async function proposeMultiSafeTransactions(transactions: MetaTransaction[]): Promise<void> {
  if (!MULTI_SIG) throw new Error("MULTI_SIG is required for DRY_RUN=Safe");
  const [signer] = await ethers.getSigners();
  const { chainId } = await ethers.provider.getNetwork();
  const proposer = await signer.getAddress();
  await writeSafeProposal(buildSafeTransactionBuilderPayload({
    safe: MULTI_SIG,
    proposer,
    chainId: chainId.toString(),
    networkName: network.name,
    serviceUrl: SAFE_TX_SERVICE_URL,
    transactions,
  }));
}
