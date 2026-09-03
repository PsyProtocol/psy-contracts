import type { ProtocolNetwork } from '../protocol-config/types'

export type DeployedContracts = {
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

/** @deprecated Use DeployedContracts. */
export type DeploymentContracts = DeployedContracts
export type DeploymentRegistry = Partial<Record<ProtocolNetwork, DeployedContracts>>
export type ActiveDeployments<N extends ProtocolNetwork> = Record<N, DeployedContracts>

export function requireDeployments<N extends ProtocolNetwork>(
  networks: readonly N[],
  registry: DeploymentRegistry,
): ActiveDeployments<N> {
  const missing = networks.filter((network) => !registry[network])
  if (missing.length) {
    throw new Error(`Missing deployed-contracts.json for: ${missing.join(', ')}`)
  }
  return Object.fromEntries(
    networks.map((network) => [network, registry[network] as DeployedContracts]),
  ) as ActiveDeployments<N>
}

let deploymentModules: Record<string, DeployedContracts> = {}

try {
  deploymentModules = import.meta.glob('./*/deployed-contracts.json', {
    eager: true,
    import: 'default',
  }) as Record<string, DeployedContracts>
} catch {
  // Bun/Node do not provide Vite's import.meta.glob. Consumers fall back to
  // protocol-config when no generated deployment is available.
}

const protocolNetworks = new Set<ProtocolNetwork>([
  'localhost', 'localhostBsc', 'localhostBase',
  'sepolia', 'bscTestnet', 'baseSepolia',
  'ethereum', 'bsc', 'base',
])

export const deployments: DeploymentRegistry = Object.fromEntries(
  Object.entries(deploymentModules).flatMap(([modulePath, deployment]) => {
    const network = modulePath.match(/^\.\/([^/]+)\/deployed-contracts\.json$/)?.[1]
    return network && protocolNetworks.has(network as ProtocolNetwork)
      ? [[network, deployment]]
      : []
  }),
) as DeploymentRegistry

const importMetaEnv = import.meta.env
const configuredNetwork = String(importMetaEnv?.VITE_NETWORK ?? 'localhost').trim()
const isFork = String(importMetaEnv?.VITE_FORK ?? 'false').trim().toLowerCase() === 'true'
const selectedNetwork: ProtocolNetwork = isFork ? 'localhost' : (
  protocolNetworks.has(configuredNetwork as ProtocolNetwork)
    ? configuredNetwork as ProtocolNetwork
    : 'localhost'
)

/** Compatibility export for callers that still operate on one selected L1. */
export const currentDeployment: DeployedContracts | undefined = deployments[selectedNetwork]
