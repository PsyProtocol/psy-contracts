import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { protocolConfig, resolveProtocolNetworkName } from "../protocol-config";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { get, getArtifact, log, save } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const protocolNetwork = resolveProtocolNetworkName(network.name);

  log("Running 004_deploy_gateways on " + network.name);
  const provider = await get("PsyAddressesProvider");
  const bridge = await get("Bridge");

  await deploy(hre, "ERC20Gateway", {
    from: deployer,
    log: true,
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [cfg.admin, provider.address],
        },
      },
    },
  });

  const protocolChain = protocolConfig.chains[protocolNetwork];
  let wethAddress: string;
  if (cfg.weth || protocolChain.wethAddress) {
    wethAddress = cfg.weth ?? protocolChain.wethAddress!;
    const artifact = await getArtifact("WETH9");
    await save("WETH9", { abi: artifact.abi, address: wethAddress });
    log("Using configured WETH for " + network.name + ": " + wethAddress);
  } else {
    const weth = await deploy(hre, "WETH9", {
      from: deployer,
      args: [],
      log: true,
    });
    wethAddress = weth.address;
  }

  await deploy(hre, "ETHGateway", {
    from: deployer,
    log: true,
    proxy: {
      owner: cfg.admin,
      proxyContract: "OpenZeppelinTransparentProxy",
      execute: {
        init: {
          methodName: "initialize",
          args: [cfg.admin, provider.address, wethAddress],
        },
      },
    },
  });

  for (const token of Object.values(protocolConfig.tokens)) {
    const deployment = token.deployments[protocolNetwork];
    if (!deployment?.deployName) continue;
    if (deployment.l1Address) {
      const artifact = await getArtifact(deployment.deployName);
      await save(deployment.deployName, { abi: artifact.abi, address: deployment.l1Address });
      log(`Using configured ${deployment.deployName} for ${network.name}: ${deployment.l1Address}`);
      continue;
    }
    const initialSupply = (1_000_000_000n * (10n ** BigInt(token.decimals))).toString();
    const initialHolder = token.symbol === "PSY" ? bridge.address : deployer;
    await deploy(hre, deployment.deployName, {
      from: deployer,
      log: true,
      args: [initialHolder, initialSupply],
    });
  }
};

export default func;
func.tags = ["gateways"];
func.dependencies = ["access", "bridge_flow_limits"];
