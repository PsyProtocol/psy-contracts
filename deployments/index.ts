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

const localhostModules = import.meta.glob('./localhost/deployed-contracts.json', {
  eager: true,
  import: 'default',
}) as Record<string, DeploymentContracts>

const sepoliaModules = import.meta.glob('./sepolia/deployed-contracts.json', {
  eager: true,
  import: 'default',
}) as Record<string, DeploymentContracts>

const bscModules = import.meta.glob('./bsc/deployed-contracts.json', {
  eager: true,
  import: 'default',
}) as Record<string, DeploymentContracts>

const ethereumModules = import.meta.glob('./ethereum/deployed-contracts.json', {
  eager: true,
  import: 'default',
}) as Record<string, DeploymentContracts>

const localhost = localhostModules['./localhost/deployed-contracts.json']
const sepolia = sepoliaModules['./sepolia/deployed-contracts.json']
const bsc = bscModules['./bsc/deployed-contracts.json']
const ethereum = ethereumModules['./ethereum/deployed-contracts.json']

const configuredNetwork = String(import.meta.env.VITE_NETWORK ?? 'localhost').trim().toLowerCase()
const isFork = String(import.meta.env.VITE_FORK ?? 'false').trim().toLowerCase() === 'true'
const selectedNetwork = (isFork || configuredNetwork === 'localhost')
  ? 'localhost'
  : configuredNetwork === 'sepolia' ? 'sepolia'
  : configuredNetwork === 'bsc' ? 'bsc'
  : 'ethereum'

const selectedDeployment =
  selectedNetwork === 'localhost'
    ? localhost
    : selectedNetwork === 'sepolia'
      ? sepolia
      : selectedNetwork === 'bsc'
        ? bsc
        : ethereum

export const currentDeployment: DeploymentContracts | undefined = selectedDeployment
