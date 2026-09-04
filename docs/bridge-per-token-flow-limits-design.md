# Bridge Per-Token Flow Limits Design

Scope: the governed `Bridge` per-token flow policy: `TokenFlowConfig`, the withdrawal delay tiers,
lifetime withdrawal totals, pause flags, and the guarded update paths.

## Why per-token flow limits

The bridge custody wallet is a single honeypot holding every bridged asset. Flow limits bound how
fast value can leave per token so that a compromised verifier, a mispriced token, or a runaway
exploit drains at most a bounded amount before governance or guardians can pause.

## TokenFlowConfig

```solidity
struct TokenFlowConfig {
    uint128 minDepositAmount;
    uint128 depositCap;
    uint128 smallWithdrawalMax;
    uint128 mediumWithdrawalMax;
    uint128 totalWithdrawalCap;
    uint32  smallWithdrawalDelay;
    uint32  mediumWithdrawalDelay;
    uint32  largeWithdrawalDelay;
    bool    configured;
}
```

Per token (`mapping(address => TokenFlowConfig) _tokenFlowConfigs`):

- `minDepositAmount` — smallest accepted deposit; `depositCap` — largest single deposit.
- `smallWithdrawalMax` / `mediumWithdrawalMax` — thresholds splitting withdrawals into three delay
  tiers. The predecessor bucket model (`ImportedTokenFlowConfig`: capacity + refill-per-second
  deposit buckets) is kept read-only in the pre-governance storage; the governed Bridge replaces
  the deposit bucket with the flat `depositCap`.
- `totalWithdrawalCap` — per-token lifetime withdrawal ceiling enforced against the cumulative
  `_totalWithdrawalAmounts[token]`.
- Delay tiers (`smallWithdrawalDelay <= mediumWithdrawalDelay <= largeWithdrawalDelay`, enforced):

| Withdrawal | Delay applied |
|------------|---------------|
| `amount <= smallWithdrawalMax` | `smallWithdrawalDelay` |
| `smallWithdrawalMax < amount <= mediumWithdrawalMax` | `mediumWithdrawalDelay` |
| `amount > mediumWithdrawalMax` **or** cumulative total would exceed `totalWithdrawalCap` | `largeWithdrawalDelay` |

`_registerPendingWithdrawal` computes the tier, stores
`PendingWithdrawal{token, recipient, amount, claimableAt = block.timestamp + delay}`, and advances
the lifetime total before any proof/claim path can settle the funds. Claims before `claimableAt`
revert (`PendingWithdrawalNotClaimable`); `withdrawalForceClaimExecutor` can force-settle.

## Initialization & migration

- `initializeFlowLimits(tokens, configs)` (`reinitializer(3)`) seeds governed configs; callable
  only by the proxy admin or the contract owner (`onlyFlowInitializer`).
- `initializeWithdrawalTotals(configuredTokens, configs, historicalTotals, expectedTokenSetHash,
  forceClaimExecutor)` (`reinitializer(4)`) seeds governed configs, seeds the per-token lifetime
  withdrawal totals from historical data, sets the force-claim executor, and pins
  `withdrawalTotalsTokenSetHash` so the historical totals cannot be re-seeded or tampered with.
- `_validateFlowConfig` rejects unconfigured entries, `minDepositAmount == 0`,
  `depositCap < minDepositAmount`, and any inversion of the withdrawal max/delay orderings.

## Updates

- `setTokenFlowConfig(token, next, expectedConfigHash)` — `onlyBridgeAdmin` (timelock after
  cutover). The expected hash is a CAS guard: `keccak256(abi.encode(token, config))` of the
  currently stored config; a mismatch (`StaleConfigHash`) means the caller built the update
  against stale state. Every change emits `TokenFlowConfigUpdated(token, oldHash, newHash)`.
- Scripts: `scripts/governance/bridgeFlowConfig.ts` builds the update with the live on-chain hash
  (`bridge:set-flow-config` task); manifests are JSON files
  (`BRIDGE_FLOW_LIMITS_FILE` / `--manifest`) listing tokens, configs, and historical totals.
- Pause flags are separate from flow configs: `guardianPauseToken` / `guardianPauseGlobal`
  (`onlyGuardian`, additive OR, break-glass) versus `setTokenPauseFlags` /
  `setGlobalPauseFlags` (`onlyBridgeAdmin`, replaces the flags). Effective flags are
  `global | token`; rescues require the global flags to be fully set.

## Invariants

1. Withdrawal delay grows monotonically with size; the largest tier also triggers on lifetime-cap
   breach, so no sequence of small withdrawals bypasses the large-withdrawal delay.
2. Lifetime totals are append-only after `initializeWithdrawalTotals`; the token-set hash pins
   which tokens the totals cover.
3. Every config mutation is hash-guarded and evented, giving an off-chain audit trail of
   `oldHash -> newHash` transitions.
4. Configuration and pausing are admin/governance operations routed through
   `ExecutorWithTimelock` after the cutover; guardians can only pause, never reconfigure.