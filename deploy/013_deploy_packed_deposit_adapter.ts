import type { DeployFunction } from "hardhat-deploy/types";
import { deploy } from "../helpers/deploy-helper";

// Explicitly selected transport deployment only. No proxy upgrade, access-layer
// rewiring or proof setup changes. Intentionally has no deployment dependencies.
const func: DeployFunction = async (hre) => {
  const { deployer } = await hre.getNamedAccounts();
  const bridge = await hre.deployments.get("Bridge");
  if ((await hre.ethers.provider.getCode(bridge.address)) === "0x") {
    throw new Error("Packed deposit adapter requires an existing deployed Bridge");
  }
  const adapter = await deploy(hre, "PackedDepositAppendAdapter", {
    from: deployer,
    args: [bridge.address],
    log: true,
  });
  const instance = await hre.ethers.getContractAt("PackedDepositAppendAdapter", adapter.address);
  if ((await instance.BRIDGE()).toLowerCase() !== bridge.address.toLowerCase()) {
    throw new Error("Packed deposit adapter Bridge mismatch");
  }
};

func.tags = ["packed-deposit-adapter"];
func.skip = async () => process.env.PSY_DEPLOY_PACKED_DEPOSIT !== "1";
export default func;
