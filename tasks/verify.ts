import { task } from "hardhat/config";
import { verifyDeployments } from "../helpers/verify-contract";

task("verify-contracts", "Verify all deployed contracts on Etherscan").setAction(
  async (_, hre) => {
    await verifyDeployments(hre);
  },
);
