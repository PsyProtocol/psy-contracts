import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { protocolConfig, resolveProtocolNetworkName } from "../protocol-config";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { execute, get, read, log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const txFrom = cfg.admin || deployer;
  const protocolNetwork = resolveProtocolNetworkName(hre.network.name);

  await get("PsyAddressesProvider");
  const bridge = await get("Bridge");
  const stateManager = await get("StateManager");
  const router = await get("Router");
  const erc20Gateway = await get("ERC20Gateway");
  const ethGateway = await get("ETHGateway");
  const verifier = await get("ZKVerifier");
  const depositBatchVerifier = await get("DepositBatchVerifier");
  const withdrawalClaimVerifier = await get("WithdrawalClaimVerifier");
  const bridgeId = (await read("PsyAddressesProvider", "BRIDGE_ID")) as string;
  const stateManagerId = (await read("PsyAddressesProvider", "STATE_MANAGER_ID")) as string;
  const routerId = (await read("PsyAddressesProvider", "ROUTER_ID")) as string;
  const erc20GatewayId = (await read("PsyAddressesProvider", "ERC20_GATEWAY_ID")) as string;
  const ethGatewayId = (await read("PsyAddressesProvider", "ETH_GATEWAY_ID")) as string;
  const zkVerifierId = (await read("PsyAddressesProvider", "ZK_VERIFIER_ID")) as string;
  const aclManagerId = (await read("PsyAddressesProvider", "ACL_MANAGER_ID")) as string;

  log("Running 006_wire_core");

  const ensureAddress = async (id: string, expected: string) => {
    const cur = (await read("PsyAddressesProvider", "getAddress", id)) as string;
    if (cur.toLowerCase() !== expected.toLowerCase()) {
      await execute("PsyAddressesProvider", { from: txFrom, log: true }, "setAddress", id, expected);
    }
  };

  await ensureAddress(bridgeId, bridge.address);
  await ensureAddress(stateManagerId, stateManager.address);
  await ensureAddress(routerId, router.address);
  await ensureAddress(erc20GatewayId, erc20Gateway.address);
  await ensureAddress(ethGatewayId, ethGateway.address);
  await ensureAddress(zkVerifierId, verifier.address);
  const acl = await get("PsyACLManager");
  await ensureAddress(aclManagerId, acl.address);

  const currentDepositBatchVerifier = (await read("Bridge", "depositBatchVerifier")) as string;
  if (currentDepositBatchVerifier.toLowerCase() !== depositBatchVerifier.address.toLowerCase()) {
    await execute("Bridge", { from: txFrom, log: true }, "setDepositBatchVerifier", depositBatchVerifier.address);
  }

  const currentWithdrawalClaimVerifier = (await read("Bridge", "withdrawalClaimVerifier")) as string;
  if (currentWithdrawalClaimVerifier.toLowerCase() !== withdrawalClaimVerifier.address.toLowerCase()) {
    await execute("Bridge", { from: txFrom, log: true }, "setWithdrawalClaimVerifier", withdrawalClaimVerifier.address);
  }

  for (const token of Object.values(protocolConfig.tokens)) {
    const deployment = token.deployments[protocolNetwork];
    if (!deployment) continue;
    let l1Address = deployment.l1Address;
    if (!l1Address && deployment.deployName) {
      l1Address = (await get(deployment.deployName)).address;
    }
    if (!l1Address) continue;
    const current = (await read("Router", "l1ToL2Token", l1Address)) as string;
    if (current !== token.l2TokenContractId) {
      await execute("Router", { from: txFrom, log: true }, "setTokenMapping", l1Address, token.l2TokenContractId);
    }
  }
};

export default func;
func.tags = ["wire"];
func.dependencies = ["access", "verifier", "state_manager", "bridge", "gateways", "bridge_flow_limits", "router"];
