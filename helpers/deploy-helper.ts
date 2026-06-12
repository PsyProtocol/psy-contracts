/**
 * Unified contract deployment with auto-registration for verification.
 *
 * Mirrors paraspace-core's `withSaveAndVerify` pattern:
 *   1. deploy contract
 *   2. register metadata (for later batch verify)
 *   3. optionally verify immediately on Etherscan
 */
import { promises as fsp } from "fs";
import path from "path";
import type { DeployOptions, DeployResult } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";

import { registerVerification } from "./verify-registry";
import { verifyContract } from "./verify-contract";

export type DeployWithVerifyOptions = DeployOptions & {
  /** If true, immediately verify on Etherscan after deploy */
  verify?: boolean;
};

/**
 * Read back hardhat-deploy's just-written deployment file to get
 * actual constructor args (template-replaced for proxies).
 */
async function readDeploymentMeta(
  hre: HardhatRuntimeEnvironment,
  name: string,
): Promise<{ address: string; args: unknown[]; sourceName?: string; contractName?: string } | null> {
  const file = path.join(hre.config.paths.deployments!, hre.network.name, `${name}.json`);
  try {
    const raw = await fsp.readFile(file, "utf8");
    const data = JSON.parse(raw);
    let sourceName: string | undefined = data.sourceName;
    let contractName: string | undefined = data.contractName;
    // If deployment JSON lacks sourceName, try to resolve from artifact
    if (!sourceName) {
      try {
        const artifact = await hre.deployments.getArtifact(name);
        sourceName = artifact.sourceName ?? artifact.contractName;
        contractName = artifact.contractName;
      } catch {}
    }
    return { address: data.address, args: data.args ?? [], sourceName, contractName };
  } catch {
    return null;
  }
}

/**
 * Deploy a contract and save verification metadata.
 *
 * For proxy deploys, registers:
 *   - <Name>_Implementation – the implementation contract (verified)
 *   - <Name>_Proxy          – proxy contract (marked skipVerify — it's standard OpenZeppelin;
 *                             Etherscan auto-detects proxy patterns)
 *   - <Name>                – main entry (proxy address, full ABI)
 *
 * Usage:
 *   import { deploy } from "../helpers/deploy-helper";
 *   await deploy(hre, "MyContract", { from: deployer, args: [...], verify: true });
 */
export async function deploy(
  hre: HardhatRuntimeEnvironment,
  name: string,
  options: DeployWithVerifyOptions,
): Promise<DeployResult> {
  const { deployments } = hre;
  const { log } = deployments;

  const isProxy = !!options.proxy;
  const { verify: shouldVerifyNow = false, ...deployOptions } = options;

  const result = await deployments.deploy(name, deployOptions);

  if (!result.newlyDeployed) {
    log(`[deploy] ${name} already deployed at ${result.address}`);
    return result;
  }

  log(`[deploy] ${name} → ${result.address}`);

  // ── Save verification metadata ──────────────────────────
  if (isProxy) {
    // Implementation — always verify (contains our business logic)
    const implName = `${name}_Implementation`;
    const implMeta = await readDeploymentMeta(hre, implName);
    if (implMeta) {
      await registerVerification(hre, implName, implMeta.address, {
        constructorArgs: implMeta.args,
        libraries: deployOptions.libraries,
        sourceName: implMeta.sourceName,
        contractName: implMeta.contractName,
      });
      if (shouldVerifyNow) {
        await verifyContract(hre, implName, implMeta.address, {
          constructorArgs: implMeta.args,
          libraries: deployOptions.libraries,
        });
      }
    }

    // Proxy — mark skipVerify (standard bytecode, auto-detected by Etherscan)
    const proxyName = `${name}_Proxy`;
    const proxyMeta = await readDeploymentMeta(hre, proxyName);
    if (proxyMeta) {
      // The proxy is TransparentUpgradeableProxy by hardhat-deploy's OpenZeppelinTransparentProxy.
      // Constructor: (_logic, admin_, _data)
      await registerVerification(hre, proxyName, proxyMeta.address, {
        constructorArgs: proxyMeta.args,
        libraries: deployOptions.libraries,
        fqnOverride:
          "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
        skipVerify: true,
      });
    }

    // Main entry (proxy address, merged ABI)
    // IMPORTANT: do not batch-verify this entry against the implementation artifact.
    // The on-chain bytecode at `name` is proxy bytecode, not implementation bytecode.
    await registerVerification(hre, name, result.address, {
      constructorArgs: proxyMeta?.args ?? [],
      libraries: deployOptions.libraries,
      skipVerify: true,
    });
  } else {
    // Resolve sourceName from: deployment JSON → artifact → deploy options → fallback
    let sourceName: string | undefined;
    let contractName: string | undefined;
    const deployMeta = await readDeploymentMeta(hre, name);
    if (deployMeta?.sourceName) {
      sourceName = deployMeta.sourceName;
      contractName = deployMeta.contractName;
    } else if (deployOptions.contract) {
      const parts = deployOptions.contract.split(":");
      sourceName = parts[0];
      contractName = parts[1] ?? name;
    }

    await registerVerification(hre, name, result.address, {
      constructorArgs: deployOptions.args ?? [],
      libraries: deployOptions.libraries,
      sourceName,
      contractName,
    });
    if (shouldVerifyNow) {
      await verifyContract(hre, name, result.address, {
        constructorArgs: deployOptions.args ?? [],
        libraries: deployOptions.libraries,
      });
    }
  }

  return result;
}
