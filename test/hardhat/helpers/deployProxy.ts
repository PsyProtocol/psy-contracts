import { ethers } from "hardhat";

async function waitForContractDeployment(contract: any) {
  if (typeof contract.waitForDeployment === "function") {
    await contract.waitForDeployment();
    return;
  }
  if (typeof contract.deployed === "function") {
    await contract.deployed();
    return;
  }
  throw new Error("Unsupported ethers contract deployment API");
}

async function getContractAddress(contract: any): Promise<string> {
  if (typeof contract.address === "string") {
    return contract.address;
  }
  if (typeof contract.target === "string") {
    return contract.target;
  }
  if (typeof contract.getAddress === "function" && contract.interface?.getFunction?.("getAddress") == null) {
    return await contract.getAddress();
  }
  throw new Error("Unable to resolve deployed contract address");
}

export async function deployProxy(contractName: string, initArgs: unknown[] = []) {
  const implementationFactory = await ethers.getContractFactory(contractName);
  const implementation = await implementationFactory.deploy();
  await waitForContractDeployment(implementation);

  const initData = implementationFactory.interface.encodeFunctionData("initialize", initArgs);
  const proxyFactory = await ethers.getContractFactory("TestERC1967Proxy");
  const implementationAddress = await getContractAddress(implementation);
  const proxy = await proxyFactory.deploy(implementationAddress, initData);
  await waitForContractDeployment(proxy);
  const proxyAddress = await getContractAddress(proxy);

  const attached = implementationFactory.attach(proxyAddress) as any;
  if (attached.address == null) {
    attached.address = proxyAddress;
  }
  return attached;
}
