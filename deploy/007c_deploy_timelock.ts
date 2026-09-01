import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { deploy } from "../helpers/deploy-helper";

const DEFAULT_DELAY = 48 * 60 * 60;
const DEFAULT_GRACE_PERIOD = 7 * 24 * 60 * 60;
const DEFAULT_MINIMUM_DELAY = 60 * 60;
const DEFAULT_MAXIMUM_DELAY = 7 * 24 * 60 * 60;

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error(`Invalid ${name}: ${raw}`);
  return parsed;
}

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { log } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);

  const admin = process.env.TIMELOCK_ADMIN || cfg.owner;
  const delay = envInt("TIMELOCK_DELAY", DEFAULT_DELAY);
  const gracePeriod = envInt("TIMELOCK_GRACE_PERIOD", DEFAULT_GRACE_PERIOD);
  const minimumDelay = envInt("TIMELOCK_MINIMUM_DELAY", DEFAULT_MINIMUM_DELAY);
  const maximumDelay = envInt("TIMELOCK_MAXIMUM_DELAY", DEFAULT_MAXIMUM_DELAY);

  log(`Running 007c_deploy_timelock on ${network.name}`);
  log(`ExecutorWithTimelock admin=${admin} delay=${delay}`);

  await deploy(hre, "ExecutorWithTimelock", {
    from: deployer,
    log: true,
    args: [admin, delay, gracePeriod, minimumDelay, maximumDelay],
  });
};

export default func;
func.tags = ["timelock"];
func.dependencies = ["bridge"];
