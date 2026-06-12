import type { ProtocolConfig } from './types'

const SEPOLIA_DEFAULT_RPC_URL =
  (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env
    ?.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'

export * from './types'

export function resolveProtocolNetworkName(networkName: string): keyof ProtocolConfig['chains'] {
  if (networkName === 'hardhat') return 'localhost'
  if (networkName === 'localhost' || networkName === 'sepolia' || networkName === 'ethereum' || networkName === 'bsc') return networkName
  throw new Error(`Unsupported protocol network: ${networkName}`)
}

export const protocolConfig: ProtocolConfig = {
  activeNetworks: ['sepolia', 'bsc'],
  chains: {
    localhost: {
      network: 'localhost',
      l1ChainId: 31337,
      l1ChainIndex: 0,
      name: 'Local Ethereum',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: 'http://127.0.0.1:8545',
      defaultExplorerUrl: 'http://127.0.0.1:8545',
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
    bsc: {
      network: 'bsc',
      l1ChainId: 56,
      l1ChainIndex: 3,
      name: 'BNB Smart Chain',
      shortName: 'BNB',
      nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
      defaultRpcUrl: 'https://bsc-dataseed.bnbchain.org',
      defaultExplorerUrl: 'https://bscscan.com',
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
        bsc: { deployName: 'PsyToken' },
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
        bsc: { deployName: 'USDTToken' },
      },
    },
  },
}
