# Governance & Access Control Design

Scope: `PsyACLManager`, `ExecutorWithTimelock`, the transparent-proxy `DefaultProxyAdmin`, and the
cutover scripts under `deploy/007*` / `scripts/governance/`.

## Role model

`PsyACLManager` (upgradeable, `AccessControlUpgradeable` + `OwnableUpgradeable`) defines five
application roles plus OpenZeppelin's `DEFAULT_ADMIN_ROLE`:

| Role | Constant | Granted at initialize to | Governs |
|------|----------|--------------------------|---------|
| `DEFAULT_ADMIN_ROLE` | `0x00` | `owner_` (config `admin`) | Administers every other ACL role |
| `BRIDGE_ADMIN_ROLE` | `keccak256("BRIDGE_ADMIN")` | `bridgeAdmin_` | Bridge flow configs, pause flags, force-set-state, rescues |
| `ROUTER_ADMIN_ROLE` | `keccak256("ROUTER_ADMIN")` | `routerAdmin_` | Router administration |
| `STATE_MANAGER_ADMIN_ROLE` | `keccak256("STATE_MANAGER_ADMIN")` | `stateManagerAdmin_` | StateManager administration |
| `PROPOSER_ROLE` | `keccak256("PROPOSER")` | `proposer_` | `StateManager.finalize` (checkpoint proposal) |
| `GUARDIAN_ROLE` | `keccak256("GUARDIAN")` | nobody at initialize | Bridge emergency pause only (additive OR of flags) |

`PsyACLManager` is `OwnableUpgradeable`; its `owner()` is the upgrade/admin identity for the ACL
proxy itself, separate from `DEFAULT_ADMIN_ROLE`.

## Ownership layers

1. **Contract admin roles** — held on `PsyACLManager`, checked by each contract through
   `PsyAddressesProvider -> ACL_MANAGER_ID`. `Bridge` resolves `isBridgeAdmin` / `isGuardian`
   dynamically on every guarded call.
2. **Proxy administration** — every upgradeable contract sits behind an OpenZeppelin v5 transparent
   proxy owned by `DefaultProxyAdmin` (Ownable).
3. **Timelock** — `ExecutorWithTimelock` is a single-admin, Aave/Paraspace-style executor:
   - `queueTransaction(target, value, signature, data, executionTime)` requires
     `executionTime >= block.timestamp + delay`.
   - The action hash is `keccak256(abi.encode(target, value, signature, data, executionTime))`
     (5 fields; no delegatecall flag — the executor only performs plain calls).
   - `executeTransaction` enforces the delay window and `GRACE_PERIOD`; `cancelTransaction` is
     admin-only.
   - Admin rotation is two-step: `setPendingAdmin` (timelock-only) then `acceptAdmin`
     (pending-admin-only).

## Deployment & cutover

- `deploy/007c_deploy_timelock.ts` deploys the executor with `admin = TIMELOCK_ADMIN || cfg.owner`
  and delay bounds `TIMELOCK_(DELAY|GRACE_PERIOD|MINIMUM_DELAY|MAXIMUM_DELAY)`.
- `deploy/007d_grant_timelock_roles.ts` (opt-in via `GRANT_TIMELOCK_ROLES=1`) grants
  `DEFAULT_ADMIN_ROLE`, `BRIDGE_ADMIN_ROLE`, `ROUTER_ADMIN_ROLE`, `STATE_MANAGER_ADMIN_ROLE` to the
  timelock, grants `GUARDIAN_ROLE` to the Governance Safe, and optionally
  (`REVOKE_REPLACED_ADMIN_ROLES=1`) revokes the replaced admin roles.
- `deploy/007e_transfer_proxy_admin_to_timelock.ts` (opt-in via
  `TRANSFER_PROXY_ADMIN_TO_TIMELOCK=1`) transfers `DefaultProxyAdmin` ownership to the timelock.
  On non-local networks the script refuses to run without the flag: the proxy-admin cutover is a
  required gate, not a silent skip.
- `scripts/governance/permissions.ts` builds the ordered, idempotent Safe batch
  (`governance:migrate-permissions`):
  1. Grant the four admin roles to the timelock (skipped when already held).
  2. Grant `GUARDIAN_ROLE` to the Governance Safe.
  3. Transfer each Ownable to the timelock (fails loudly if an Ownable is owned by neither the
     Safe nor the timelock).
  4. Revoke roles from every replaced admin account in this order: `BRIDGE_ADMIN`,
     `ROUTER_ADMIN`, `STATE_MANAGER_ADMIN`, `GUARDIAN`, then `DEFAULT_ADMIN_ROLE` last (revoking
     it earlier would break later revocations). The Governance Safe keeps `GUARDIAN_ROLE`; every
     other replaced admin that holds `GUARDIAN_ROLE` is stripped. `PROPOSER_ROLE` is never touched.
- `governance:verify-permissions` is the all-green gate after cutover; it fails on any of:
  - Timelock missing any of the four admin roles.
  - Any stripped-account address still holding `BRIDGE_ADMIN_ROLE`, `ROUTER_ADMIN_ROLE`,
    `STATE_MANAGER_ADMIN_ROLE`, `DEFAULT_ADMIN_ROLE`, or `GUARDIAN_ROLE` (Governance Safe exempt
    from the `GUARDIAN_ROLE` check, which is instead required of it).
  - Any Ownable not owned by the timelock, nonzero timelock pending admin, or the
    `PsyAddressesProvider` pointing at a different ACL.
  - Role-separation violations (see below).

## Role separation

`PROPOSER_ROLE` is an **operational bot role**, deliberately outside the governance migration:

- It is held by a dedicated proposer address (config `proposer`) that must be distinct from the
  deployer/admin, the Governance Safe, and the timelock contract. Governance executes protocol
  administration; the bot is the only account allowed to finalize checkpoints on `StateManager`.
- The cutover batch does not migrate or revoke `PROPOSER_ROLE`, so it survives governance
  cutovers by design — rotating the Safe or retiming the timelock never interrupts the proposer.
- Verification enforces the separation: `governance:verify-permissions` reports a violation when
  the timelock or the Governance Safe holds `PROPOSER_ROLE`, when the configured proposer
  (`--proposer`) equals the timelock or the Governance Safe, when the configured proposer does not
  actually hold the role, or when no proposer is configured at all. A replaced admin still holding
  `PROPOSER_ROLE` (i.e. the replaced admin doubling as the bot) is also a violation.

## Operational paths after cutover

- Upgrades and rescues go through the timelock: `DRY_RUN=TimeLock` prints queue/execute/cancel
  calldata; `DRY_RUN=SafeWithTimeLock` wraps the timelock calldata in a Safe proposal.
- `Bridge.guardianPauseToken` / `guardianPauseGlobal` remain directly callable by the Governance
  Safe (emergency break-glass), while un-pausing and flow-config edits are admin (timelock) paths.
- Rescues (`rescueERC20`, `rescueNative`, `rescueWETHAsNative`) require the bridge to be fully
  paused and are `BRIDGE_ADMIN_ROLE` (timelock) operations.