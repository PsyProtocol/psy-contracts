import { upgradeContract } from "./utils";

export async function upgradeERC20Gateway(executionTime?: string) {
  return upgradeContract("ERC20Gateway", "ERC20Gateway", executionTime);
}

export async function upgradeETHGateway(executionTime?: string) {
  return upgradeContract("ETHGateway", "ETHGateway", executionTime);
}

if (require.main === module) {
  const target = process.env.GATEWAY || "all";
  const run = async () => {
    if (target === "erc20" || target === "all") await upgradeERC20Gateway(process.env.TIMELOCK_EXECUTION_TIME);
    if (target === "eth" || target === "all") await upgradeETHGateway(process.env.TIMELOCK_EXECUTION_TIME);
  };
  run().catch((err: unknown) => {
    console.error(err);
    process.exit(1);
  });
}
