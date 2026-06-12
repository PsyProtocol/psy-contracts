import type { DeployFunction } from "hardhat-deploy/types";
import type { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadDeployConfig } from "./deploy-config";
import { deploy } from "../helpers/deploy-helper";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network } = hre;
  const { save, log, getArtifact } = deployments;
  const { deployer } = await getNamedAccounts();
  const cfg = await loadDeployConfig(hre);
  const verifierArtifact = "src/GnarkGroth16Verifier.sol:Verifier";
  const verifierDeployment = "ZKVerifier";
  const withdrawalClaimVerifierArtifact = "src/WithdrawalClaimVerifier.sol:Verifier";
  const withdrawalClaimVerifierDeployment = "WithdrawalClaimVerifier";
  const depositBatchVerifierArtifact = "src/DepositBatchVerifier.sol:Verifier";
  const depositBatchVerifierDeployment = "DepositBatchVerifier";

  log(`Running 001_deploy_verifier on ${network.name}`);
  if (cfg.verifier) {
    const artifact = await getArtifact(verifierArtifact);
    await save(verifierDeployment, {
      abi: artifact.abi,
      address: cfg.verifier,
    });
    log(`Using external bridge agg verifier from config: ${cfg.verifier}`);
  }
  if (!cfg.verifier) {
    await deploy(hre, verifierDeployment, {
      contract: verifierArtifact,
      from: deployer,
      args: [],
      log: true,
    });
  }

  if (cfg.withdrawalClaimVerifier) {
    const artifact = await getArtifact(withdrawalClaimVerifierArtifact);
    await save(withdrawalClaimVerifierDeployment, {
      abi: artifact.abi,
      address: cfg.withdrawalClaimVerifier,
    });
    log(`Using external withdrawal claim verifier from config: ${cfg.withdrawalClaimVerifier}`);
  } else {
    await deploy(hre, withdrawalClaimVerifierDeployment, {
      contract: withdrawalClaimVerifierArtifact,
      from: deployer,
      args: [],
      log: true,
    });
  }

  if (cfg.depositBatchVerifier) {
    const artifact = await getArtifact(depositBatchVerifierArtifact);
    await save(depositBatchVerifierDeployment, {
      abi: artifact.abi,
      address: cfg.depositBatchVerifier,
    });
    log(`Using external deposit batch verifier from config: ${cfg.depositBatchVerifier}`);
  } else {
    await deploy(hre, depositBatchVerifierDeployment, {
      contract: depositBatchVerifierArtifact,
      from: deployer,
      args: [],
      log: true,
    });
  }
};

export default func;
func.tags = ["verifier"];
