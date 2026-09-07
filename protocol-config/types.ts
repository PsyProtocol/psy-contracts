export type ProtocolNetwork =
  | 'localhost'
  | 'localhostBsc'
  | 'localhostBase'
  | 'sepolia'
  | 'bscTestnet'
  | 'baseSepolia'
  | 'ethereum'
  | 'bsc'
  | 'base'
export type BridgeChain = 'ethereum' | 'bsc' | 'base'
export type ProtocolTokenSymbol = 'PSY' | 'USDT'

export type ProtocolChainConfig = {
  network: ProtocolNetwork
  /** Logical bridge chain. Testnets share their mainnet chain's index. */
  bridgeChain: BridgeChain
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
  /**
   * Overrides the token's `displaySymbol` on this network.
   *
   * One token key can point at genuinely different assets per network: the
   * USDT key is Psy's own testnet token on the testnets and Tether's real
   * contract on Ethereum. They must not share a display name.
   */
  displaySymbol?: string
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
