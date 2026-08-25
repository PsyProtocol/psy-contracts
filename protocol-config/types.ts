export type ProtocolNetwork = 'localhost' | 'sepolia' | 'bsc-testnet' | 'ethereum'
export type ProtocolTokenSymbol = 'PSY' | 'USDT'

export type ProtocolChainConfig = {
  network: ProtocolNetwork
  l1ChainId: number
  l1ChainIndex: number
  name: string
  shortName: string
  nativeCurrency: {
    name: string
    symbol: string
    decimals: number
  }
  defaultRpcUrl?: string
  defaultExplorerUrl?: string
  wethAddress?: string
}

export type ProtocolTokenDeployment = {
  deployName?: string
  l1Address?: string
}

export type ProtocolTokenConfig = {
  symbol: ProtocolTokenSymbol
  displaySymbol: string
  icon: string
  decimals: number
  l2TokenContractId: string
  deployments: Partial<Record<ProtocolNetwork, ProtocolTokenDeployment>>
}

export type ProtocolConfig = {
  activeNetworks: ProtocolNetwork[]
  chains: Record<ProtocolNetwork, ProtocolChainConfig>
  tokens: Record<ProtocolTokenSymbol, ProtocolTokenConfig>
}
