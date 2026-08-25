export type DeploymentContracts = {
  network: string
  chainId: string | number
  generatedAt?: string
  protocol?: {
    chain?: unknown
    tokens?: Record<string, { l1Address: string; l2TokenContractId: string; decimals: number; symbol: string }>
  }
  core?: Record<string, string>
  contracts?: Record<string, string>
  proxies?: Record<string, string>
  implementations?: Record<string, string>
}

let localhostModules: Record<string, DeploymentContracts> = {}
let sepoliaModules: Record<string, DeploymentContracts> = {}
let bscTestnetModules: Record<string, DeploymentContracts> = {}
let ethereumModules: Record<string, DeploymentContracts> = {}

try {
  localhostModules = import.meta.glob('./localhost/deployed-contracts.json', {
    eager: true,
    import: 'default',
  }) as Record<string, DeploymentContracts>
  sepoliaModules = import.meta.glob('./sepolia/deployed-contracts.json', {
    eager: true,
    import: 'default',
  }) as Record<string, DeploymentContracts>
  bscTestnetModules = import.meta.glob('./bsc-testnet/deployed-contracts.json', {
    eager: true,
    import: 'default',
  }) as Record<string, DeploymentContracts>
  ethereumModules = import.meta.glob('./ethereum/deployed-contracts.json', {
    eager: true,
    import: 'default',
  }) as Record<string, DeploymentContracts>
} catch {
  // Bun/Node do not provide Vite's import.meta.glob. Consumers fall back to
  // protocol-config when no generated deployment is available.
}

const localhost = localhostModules['./localhost/deployed-contracts.json']
const sepolia = sepoliaModules['./sepolia/deployed-contracts.json']
const bscTestnet = bscTestnetModules['./bsc-testnet/deployed-contracts.json']
const ethereum = ethereumModules['./ethereum/deployed-contracts.json']

const importMetaEnv = import.meta.env

const configuredNetwork = String(importMetaEnv?.VITE_NETWORK ?? 'localhost').trim().toLowerCase()
const isFork = String(importMetaEnv?.VITE_FORK ?? 'false').trim().toLowerCase() === 'true'
const selectedNetwork = isFork ? 'localhost' : configuredNetwork

const selectedDeployment =
  selectedNetwork === 'localhost'
    ? localhost
    : selectedNetwork === 'sepolia'
      ? sepolia
      : selectedNetwork === 'bsc-testnet'
        ? bscTestnet
        : selectedNetwork === 'ethereum'
          ? ethereum
          : undefined

export const currentDeployment: DeploymentContracts | undefined = selectedDeployment
