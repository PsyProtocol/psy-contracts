import type { ProtocolConfig } from './types'

const ENV =
  (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env || {}

function envNumber(name: string, fallback: number): number {
  const raw = ENV[name]
  if (!raw) return fallback
  const parsed = Number(raw)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback
}

const LOCALHOST_DEFAULT_CHAIN_ID = envNumber('LOCALHOST_L1_CHAIN_ID', 31337)
const SEPOLIA_DEFAULT_RPC_URL =
  ENV.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'

function nodeLocalhostRpcUrl(): string {
  const host = ['127', '0', '0', '1'].join('.')
  return `http://${host}:8545`
}

const LOCALHOST_DEFAULT_RPC_URL =
  ENV.LOCALHOST_RPC_URL ||
  ENV.LOCALHOST_L1_RPC_URL ||
  ('window' in globalThis ? '' : nodeLocalhostRpcUrl())

export * from './types'

export function resolveProtocolNetworkName(networkName: string): keyof ProtocolConfig['chains'] {
  if (networkName === 'hardhat') return 'localhost'
  if (networkName === 'localhost' || networkName === 'sepolia' || networkName === 'ethereum') return networkName
  throw new Error(`Unsupported protocol network: ${networkName}`)
}

export const protocolConfig: ProtocolConfig = {
  activeNetworks: ['sepolia'],
  chains: {
    localhost: {
      network: 'localhost',
      l1ChainId: LOCALHOST_DEFAULT_CHAIN_ID,
      l1ChainIndex: 0,
      name: 'Local Ethereum',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: LOCALHOST_DEFAULT_RPC_URL,
      defaultExplorerUrl: LOCALHOST_DEFAULT_RPC_URL,
    },
    sepolia: {
      network: 'sepolia',
      l1ChainId: 11155111,
      l1ChainIndex: 0,
      name: 'Sepolia',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: SEPOLIA_DEFAULT_RPC_URL,
      defaultExplorerUrl: 'https://sepolia.etherscan.io',
    },
    ethereum: {
      network: 'ethereum',
      l1ChainId: 1,
      l1ChainIndex: 2,
      name: 'Ethereum',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: 'https://ethereum-rpc.publicnode.com',
      defaultExplorerUrl: 'https://etherscan.io',
    },
  },
  tokens: {
    PSY: {
      symbol: 'PSY',
      displaySymbol: 'PSY',
      icon: '/tokens/psy.svg',
      decimals: 9,
      l2TokenContractId: '0x0000000000000000000000000000000000000000000000000000000000000000',
      deployments: {
        localhost: { deployName: 'PsyToken' },
        sepolia: { deployName: 'PsyToken' },
        ethereum: { deployName: 'PsyToken' },
      },
    },
    USDT: {
      symbol: 'USDT',
      displaySymbol: 'USDT',
      icon: '/tokens/usdt.svg',
      decimals: 6,
      l2TokenContractId: '0x0000000000000000000000000000000000000000000000000000000000000004',
      deployments: {
        localhost: { deployName: 'USDTToken' },
        sepolia: { deployName: 'USDTToken' },
        ethereum: { l1Address: '0xdAC17F958D2ee523a2206206994597C13D831ec7' },
      },
    },
  },
}
