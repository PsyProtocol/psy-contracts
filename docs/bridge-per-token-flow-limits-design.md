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
- `totalWithdrawalCap` — per-token lifetime threshold against cumulative `_totalWithdrawalAmounts[token]`, not a daily allowance or a hard rejection cap. The crossing withdrawal already requires governance.
- `smallWithdrawalDelay` is retained for storage/ABI compatibility; small withdrawals always pay directly with zero delay. Medium and large delays are configurable (local defaults: one hour and seven days).

| Withdrawal (large condition takes precedence) | Settlement |
|------------|---------------|
| `amount <= smallWithdrawalMax`, next total at or below cap | Direct payout in `batchClaimWithdrawal`, no pending entry |
| `smallWithdrawalMax < amount <= mediumWithdrawalMax`, next total at or below cap | Pending; anyone can trigger payout to the original recipient after `mediumWithdrawalDelay` |
| `amount > mediumWithdrawalMax` **or** next total exceeds `totalWithdrawalCap` | Pending; only `withdrawalForceClaimExecutor` (governance Timelock) can settle after `largeWithdrawalDelay` |

The nonce and lifetime total are updated before any external transfer. An append-only shared `withdrawalSettlementLock` prevents callbacks from entering any of the three withdrawal entry points and contaminating batch receipt attribution. Direct payout emits `WithdrawalClaimed`; pending registration emits `WithdrawalPendingCreated`. A failed direct transfer reverts the whole batch, including all nonce and total changes. Pending-claim pause also blocks direct payout.

The stored `_withdrawalSettlementTiers` and `claimableAt` fix the permission and deadline at registration; later policy changes do not downgrade existing governed claims. `withdrawalRequiresGovernance(nonce)` exposes the permission. Ordinary claims reject governed pending entries even after their deadline. `forceClaimWithdrawal` honors the stored deadline and pause flags; it never pays an alternate recipient. On upgrade, existing pending entries without a recorded tier conservatively require governance and retain their stored deadline. No reinitializer or rewriting of existing pending storage is needed.

Local defaults apply the same token-quantity policy to every token and native asset: below 50,000 tokens pays directly; at least 50,000 and below 100,000 uses the medium delay; at least 100,000 requires governance. Because max fields are inclusive, they store `parseUnits("50000", decimals) - 1` and `parseUnits("100000", decimals) - 1`. The historical cumulative cap is `10^12` whole tokens, converted with the asset’s configured decimals. This is not a daily cap or a USD value. With 6 / 9 / 18 decimals, the raw caps are `10^18` / `10^21` / `10^30`, all within the existing uint128 field. Delays remain one hour and seven days. Deposits retain a one-smallest-unit minimum and a 10,000,000-token cap. Non-local deployments still require a reviewed `BRIDGE_FLOW_LIMITS_FILE`; source default changes do not update a live contract. The separate Goldilocks single-withdrawal bound is unchanged.

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