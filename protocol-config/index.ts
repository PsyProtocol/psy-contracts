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
const LOCALHOST_BSC_DEFAULT_CHAIN_ID = envNumber('LOCALHOST_BSC_L1_CHAIN_ID', 31338)
const LOCALHOST_BASE_DEFAULT_CHAIN_ID = envNumber('LOCALHOST_BASE_L1_CHAIN_ID', 31339)
const SEPOLIA_DEFAULT_RPC_URL =
  ENV.SEPOLIA_RPC_URL || 'https://ethereum-sepolia-rpc.publicnode.com'
const BSC_TESTNET_DEFAULT_RPC_URL =
  ENV.BSC_TESTNET_RPC_URL || 'https://data-seed-prebsc-1-s1.bnbchain.org:8545'
const BASE_SEPOLIA_DEFAULT_RPC_URL =
  ENV.BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org'
const BSC_DEFAULT_RPC_URL = ENV.BSC_RPC_URL || 'https://bsc-dataseed.binance.org'
const BASE_DEFAULT_RPC_URL = ENV.BASE_RPC_URL || 'https://mainnet.base.org'

function nodeLocalhostRpcUrl(port: number): string {
  const host = ['127', '0', '0', '1'].join('.')
  return `http://${host}:${port}`
}

const LOCALHOST_DEFAULT_RPC_URL =
  ENV.LOCALHOST_RPC_URL ||
  ENV.LOCALHOST_L1_RPC_URL ||
  ('window' in globalThis ? '' : nodeLocalhostRpcUrl(8545))
const LOCALHOST_BSC_DEFAULT_RPC_URL =
  ENV.LOCALHOST_BSC_RPC_URL || ('window' in globalThis ? '' : nodeLocalhostRpcUrl(9545))
const LOCALHOST_BASE_DEFAULT_RPC_URL =
  ENV.LOCALHOST_BASE_RPC_URL || ('window' in globalThis ? '' : nodeLocalhostRpcUrl(10545))

export * from './types'

export function resolveProtocolNetworkName(networkName: string): keyof ProtocolConfig['chains'] {
  if (networkName === 'hardhat') return 'localhost'
  if (
    networkName === 'localhost' ||
    networkName === 'localhostBsc' ||
    networkName === 'localhostBase' ||
    networkName === 'sepolia' ||
    networkName === 'bscTestnet' ||
    networkName === 'baseSepolia' ||
    networkName === 'ethereum' ||
    networkName === 'bsc' ||
    networkName === 'base'
  ) return networkName
  throw new Error(`Unsupported protocol network: ${networkName}`)
}

export const protocolConfig: ProtocolConfig = {
  activeNetworks: ['sepolia', 'bscTestnet', 'baseSepolia'],
  chains: {
    localhost: {
      network: 'localhost',
      bridgeChain: 'ethereum',
      l1ChainId: LOCALHOST_DEFAULT_CHAIN_ID,
      l1ChainIndex: 0,
      name: 'Local Ethereum',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: LOCALHOST_DEFAULT_RPC_URL,
      defaultExplorerUrl: LOCALHOST_DEFAULT_RPC_URL,
    },
    localhostBsc: {
      network: 'localhostBsc',
      bridgeChain: 'bsc',
      l1ChainId: LOCALHOST_BSC_DEFAULT_CHAIN_ID,
      l1ChainIndex: 1,
      name: 'Local BSC',
      shortName: 'BSC',
      nativeCurrency: { name: 'Local BNB', symbol: 'BNB', decimals: 18 },
      defaultRpcUrl: LOCALHOST_BSC_DEFAULT_RPC_URL,
      defaultExplorerUrl: LOCALHOST_BSC_DEFAULT_RPC_URL,
    },
    localhostBase: {
      network: 'localhostBase',
      bridgeChain: 'base',
      l1ChainId: LOCALHOST_BASE_DEFAULT_CHAIN_ID,
      l1ChainIndex: 2,
      name: 'Local Base',
      shortName: 'BASE',
      nativeCurrency: { name: 'Local Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: LOCALHOST_BASE_DEFAULT_RPC_URL,
      defaultExplorerUrl: LOCALHOST_BASE_DEFAULT_RPC_URL,
    },
    sepolia: {
      network: 'sepolia',
      bridgeChain: 'ethereum',
      l1ChainId: 11155111,
      l1ChainIndex: 0,
      // "Ethereum Sepolia", not "Sepolia": Base Sepolia is also configured, so
      // the bare name is ambiguous everywhere it is shown — the bridge's route
      // picker, the faucet page, activity rows. Display only; the `network` key
      // above is what tooling matches on, and no address or validation reads
      // this field. Matches the name the ops runtime manifest already uses.
      name: 'Ethereum Sepolia',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: SEPOLIA_DEFAULT_RPC_URL,
      defaultExplorerUrl: 'https://sepolia.etherscan.io',
    },
    bscTestnet: {
      network: 'bscTestnet',
      bridgeChain: 'bsc',
      l1ChainId: 97,
      l1ChainIndex: 1,
      name: 'BSC Testnet',
      shortName: 'BSC',
      nativeCurrency: { name: 'Test BNB', symbol: 'tBNB', decimals: 18 },
      defaultRpcUrl: BSC_TESTNET_DEFAULT_RPC_URL,
      defaultExplorerUrl: 'https://testnet.bscscan.com',
    },
    baseSepolia: {
      network: 'baseSepolia',
      bridgeChain: 'base',
      l1ChainId: 84532,
      l1ChainIndex: 2,
      name: 'Base Sepolia',
      shortName: 'BASE',
      nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: BASE_SEPOLIA_DEFAULT_RPC_URL,
      defaultExplorerUrl: 'https://sepolia-explorer.base.org',
    },
    ethereum: {
      network: 'ethereum',
      bridgeChain: 'ethereum',
      l1ChainId: 1,
      l1ChainIndex: 0,
      name: 'Ethereum',
      shortName: 'ETH',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: 'https://ethereum-rpc.publicnode.com',
      defaultExplorerUrl: 'https://etherscan.io',
    },
    bsc: {
      network: 'bsc',
      bridgeChain: 'bsc',
      l1ChainId: 56,
      l1ChainIndex: 1,
      name: 'BNB Smart Chain',
      shortName: 'BSC',
      nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
      defaultRpcUrl: BSC_DEFAULT_RPC_URL,
      defaultExplorerUrl: 'https://bscscan.com',
    },
    base: {
      network: 'base',
      bridgeChain: 'base',
      l1ChainId: 8453,
      l1ChainIndex: 2,
      name: 'Base',
      shortName: 'BASE',
      nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
      defaultRpcUrl: BASE_DEFAULT_RPC_URL,
      defaultExplorerUrl: 'https://basescan.org',
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
        localhostBsc: { deployName: 'PsyToken' },
        localhostBase: { deployName: 'PsyToken' },
        sepolia: { deployName: 'PsyToken' },
        bscTestnet: { deployName: 'PsyToken' },
        baseSepolia: { deployName: 'PsyToken' },
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
        localhostBsc: { deployName: 'USDTToken' },
        localhostBase: { deployName: 'USDTToken' },
        sepolia: { deployName: 'USDTToken' },
        bscTestnet: { deployName: 'USDTToken' },
        baseSepolia: { deployName: 'USDTToken' },
        ethereum: { l1Address: '0xdAC17F958D2ee523a2206206994597C13D831ec7' },
      },
    },
  },
}

/**
 * Validate immutable bridge identity invariants. Different environments for
 * one logical bridge chain (for example Sepolia and Ethereum) deliberately
 * share an index; distinct logical production chains must not.
 */
export function validateProtocolChainRegistry(config: ProtocolConfig = protocolConfig): void {
  const chainIds = new Map<number, string>()
  const bridgeIndices = new Map<number, string>()

  for (const [key, chain] of Object.entries(config.chains)) {
    if (!Number.isSafeInteger(chain.l1ChainId) || chain.l1ChainId <= 0) {
      throw new Error(`Invalid l1ChainId for ${key}: ${chain.l1ChainId}`)
    }
    if (!Number.isInteger(chain.l1ChainIndex) || chain.l1ChainIndex < 0 || chain.l1ChainIndex > 255) {
      throw new Error(`Invalid l1ChainIndex for ${key}: ${chain.l1ChainIndex}`)
    }

    const existingChainId = chainIds.get(chain.l1ChainId)
    if (existingChainId) {
      throw new Error(`Duplicate l1ChainId ${chain.l1ChainId}: ${existingChainId}, ${key}`)
    }
    chainIds.set(chain.l1ChainId, key)

    const existingBridgeChain = bridgeIndices.get(chain.l1ChainIndex)
    if (existingBridgeChain && existingBridgeChain !== chain.bridgeChain) {
      throw new Error(
        `Duplicate l1ChainIndex ${chain.l1ChainIndex}: ${existingBridgeChain}, ${chain.bridgeChain}`,
      )
    }
    bridgeIndices.set(chain.l1ChainIndex, chain.bridgeChain)
  }
}

validateProtocolChainRegistry()
