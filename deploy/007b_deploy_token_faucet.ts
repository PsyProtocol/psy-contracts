import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { protocolConfig, resolveProtocolNetworkName } from "../protocol-config";
import { deploy } from "../helpers/deploy-helper";

const USDT_DRIP_AMOUNT = 10_000n * 10n ** 6n;
const COOLDOWN_BLOCKS = 12;

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { get, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const protocolNetwork = resolveProtocolNetworkName(hre.network.name);
  const faucetOwner = cfg.admin || deployer;

  log("Running 007b_deploy_token_faucet");

  const deployed = await deploy(hre, "TokenFaucetManager", {
    from: deployer,
    log: true,
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [faucetOwner],
        },
      },
    },
  });

  log(`TokenFaucetManager deployed at ${deployed.address}`);

  const usdtDeployment = protocolConfig.tokens.USDT.deployments[protocolNetwork];
  if (!usdtDeployment?.l1Address) {
    const usdt = await get("USDTToken");
    await configureToken(hre, faucetOwner, usdt.address, USDT_DRIP_AMOUNT);
    await transferTokenOwnership(hre, "USDTToken", deployed.address);
  } else {
    log(`Skipping faucet ownership for external USDTToken: ${usdtDeployment.l1Address}`);
  }

  await removeLegacyPsyFaucetToken(hre, faucetOwner);

  if (process.env.TRANSFER_PROTOCOL_OWNERSHIP_TO_TIMELOCK === "1") {
    const timelock = await get("ExecutorWithTimelock");
    const currentOwner = (await deployments.read("TokenFaucetManager", "owner")) as string;
    if (currentOwner.toLowerCase() !== timelock.address.toLowerCase()) {
      await deployments.execute(
        "TokenFaucetManager",
        { from: currentOwner, log: true },
        "transferOwnership",
        timelock.address,
      );
    }
  }
};

async function configureToken(
  hre: HardhatRuntimeEnvironment,
  faucetOwner: string,
  tokenAddress: string,
  dripAmount: bigint,
) {
  const { deployments } = hre;
  const { execute, read } = deployments;
  const listed = (await read("TokenFaucetManager", "isListed", tokenAddress)) as boolean;

  if (listed) {
    await execute(
      "TokenFaucetManager",
      { from: faucetOwner, log: true },
      "updateTokenConfig",
      tokenAddress,
      true,
      dripAmount,
      COOLDOWN_BLOCKS,
    );
    return;
  }

  await execute(
    "TokenFaucetManager",
    { from: faucetOwner, log: true },
    "addToken",
    tokenAddress,
    true,
    dripAmount,
    COOLDOWN_BLOCKS,
  );
}

async function transferTokenOwnership(
  hre: HardhatRuntimeEnvironment,
  deployName: "USDTToken",
  faucetAddress: string,
) {
  const { deployments } = hre;
  const { execute, read } = deployments;
  const currentOwner = (await read(deployName, "owner")) as string;
  if (currentOwner.toLowerCase() === faucetAddress.toLowerCase()) return;

  await execute(deployName, { from: currentOwner, log: true }, "transferOwnership", faucetAddress);
}

async function removeLegacyPsyFaucetToken(
  hre: HardhatRuntimeEnvironment,
  faucetOwner: string,
) {
  const { deployments } = hre;
  const { execute, get, read, log } = deployments;
  const psy = await get("PsyToken");
  const listed = (await read("TokenFaucetManager", "isListed", psy.address)) as boolean;
  if (!listed) return;

  log("Removing legacy PsyToken from TokenFaucetManager");
  await execute("TokenFaucetManager", { from: faucetOwner, log: true }, "removeToken", psy.address);
}

export default func;
func.tags = ["token_faucet"];
func.dependencies = ["transfer_ownership", "bridge_flow_limits"];
