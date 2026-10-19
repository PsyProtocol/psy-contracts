# Packed deposit transport adapter

`PackedDepositAppendAdapter` is a stateless transport adapter for the existing
`Bridge.batchAppend(uint256[8],uint256[],uint256[1312])` ABI. It reconstructs and
executes each original call in order. Existing Bridge proof, commitment, root
and cursor checks apply; failure reverts the whole transaction. It has an
immutable Bridge binding, no administrator, no token allowance and no payable
entrypoint. No circuit, verifier or Bridge upgrade is required.

## Encoding

`appendPackedBatches(bytes)` accepts concatenated, fixed 8,684-byte records:

| Field | Words | Width | Bytes |
| --- | ---: | ---: | ---: |
| Groth16 proof coordinates | 8 | uint256 | 256 |
| Public inputs | 795 | uint32 | 3,180 |
| Slot data | 1,312 | uint32 | 5,248 |

All words are big-endian, in the original ABI argument order. Full proof
coordinates are retained; the producer must reject public inputs or slot words
that exceed uint32 rather than truncate them. The contract rejects empty,
misaligned or more-than-14-record payloads. The 14-record transport bound is
not a recommended execution budget: the current Relayer trial allows at most
four calls and 15,000,000 gas, with live estimation and fee checks.

## Deployment

The deployment function has only the `packed-deposit-adapter` tag and no
dependencies. It is skipped unless `PSY_DEPLOY_PACKED_DEPOSIT=1`. It requires
the existing network's `Bridge` deployment, verifies that it has code, and
checks the deployed adapter's `BRIDGE()` binding. Select only this tag through
the repository's existing keystore deployment entrypoint; do not use a full
deployment/reset to add this adapter.

The testnet deployment used source
`d161b96068915d7795195eb408e5d341679720d2`, the exact previously tested Hardhat
artifact, and `--no-compile`. Credentials and private deployment logs are not
part of this documentation.

| Network | Adapter | Existing Bridge |
| --- | --- | --- |
| Sepolia / 11155111 | `0x76Fee5DA6F1Cfed60c80F72dCB553b38DA3245c7` | `0x9809D527544054bbb7357FB5b9e484590A72f2DF` |
| BSC Testnet / 97 | `0x77E2D427793B3B6Db5eB2E33aFFDF9d2d8796C10` | `0xaf1c879A6052701bEA56373bcF6F9fB4568C7c70` |
| Base Sepolia / 84532 | `0xA07d826f3765f6E606755B85640565F7c0cae292` | `0x7740B9be2886751D9bB8E12c4548F33F20caFc70` |

The Relayer's configuration and chain-specific fee accounting are documented
in `PsyProtocol/psy-node`, `docs/relayer-packed-deposits.md`. It submits already
ready proofs immediately, validates adapter binding, and retains receipt/cursor
checks. Base's budget includes buffered L1 data and operator fees.

## Validation boundaries

The adapter and Bridge integration suites passed 13 focused Foundry tests.
Exact deployed runtime replay passed for one through four real historical
proofs on BSC and Base; mutated proofs reverted. Live single-call acceptance
advanced 32 deposits on each new chain. The later four-call configuration is
not itself evidence of a live four-call receipt on those chains.

The wider suite retains two known baseline failures:
`GnarkGroth16VerifierTest.testVerifyOutProofJsonUncompressed` and
`GnarkGroth16VerifierForkTest.testMainnetForkVerifyUncompressedProofFromOutProofJson`.
These were explicitly accepted for the scoped testnet trial; this release does
not claim a passing complete contract suite.
