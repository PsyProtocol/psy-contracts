import { ethers } from "hardhat";

const abiCoder =
  (ethers as any).AbiCoder?.defaultAbiCoder?.() ??
  ethers.utils.defaultAbiCoder;

export const DUMMY_GNARK_PROOF = abiCoder.encode(
  ["uint256[8]"],
  [[1, 2, 3, 4, 5, 6, 7, 8]]
);
