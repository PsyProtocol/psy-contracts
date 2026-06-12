import { ethers } from "hardhat";

export const DUMMY_GNARK_PROOF = ethers.utils.defaultAbiCoder.encode(
  ["uint256[8]"],
  [[1, 2, 3, 4, 5, 6, 7, 8]]
);
