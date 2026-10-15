# Security

This document records the static-analysis baseline for the protocol and the
reasoning behind every suppressed finding. Each finding is either fixed or
justified; "the tool is wrong" is never asserted without an argument for *why*.

## Running the analysis

```bash
pip install slither-analyzer
solc-select install 0.8.24 && solc-select use 0.8.24
slither . --filter-paths "lib|test|script" --exclude-dependencies
```

## Baseline

Slither 0.11.6, solc 0.8.24, 102 detectors. **76 results.** Every one is triaged
below.

| Severity | Count | Fixed | Accepted |
|---|---|---|---|
| High | 1 | 0 | 1 |
| Medium | 26 | 0 | 26 |
| Low | 41 | 0 | 41 |
| Informational | 8 | 0 | 8 |

---

## High

### `arbitrary-send-erc20` — 1 finding — **accepted (false positive)**

`LendingPool.flashLoan` (`src/LendingPool.sol:427`) pulls repayment with
`transferFrom(receiver, aToken, amount + premium)`, where `receiver` is a
caller-supplied address. Slither flags any `transferFrom` whose `from` is not
`msg.sender`.

The concern this detector encodes is "an attacker names a victim who has approved
the pool, and drains their approval." That attack does not apply here, because
the flow is closed within one transaction:

1. `transferUnderlyingTo(receiver, amount)` (`:419`) — the receiver is *given* the
   funds first.
2. `IFlashLoanReceiver(receiver).executeOperation(...)` (`:422`) — the receiver
   must return `true`.
3. Only then is `amount + premium` pulled back.

The pool itself funds the principal, so naming a victim does not let anyone
drain the victim's approval: the pull is bounded by the `amount` just sent plus
`premium`. What remains is griefing. A receiver contract whose
`executeOperation` returns `true` without checking `initiator` can be made to
pay the premium for a flash loan someone else triggered. The attacker gains
nothing, but the receiver loses the premium. Receivers must check that
`initiator` is an address they trust; the test mock documents this. The
function is additionally `nonReentrant` and `whenNotPaused`.

(An earlier version of this note said the attacker would have to send the victim
the principal first. That was wrong, since the pool sends it, and the griefing
bound above replaces it.)

This is the Aave V2/V3 flash-loan shape, and it is a deliberate design choice
documented at `:402-404`: reentrancy into the pool during the callback is blocked
rather than permitted, which is *more* conservative than Aave.

---

## Medium

### `reentrancy-no-eth` — 11 findings — **accepted**

All eleven are in `deposit`, `withdraw`, `borrow`, `repay`, `liquidationCall`,
and `flashLoan` — every one of which carries the `nonReentrant` modifier. Slither
reports the pattern without modelling the guard. No ETH is handled anywhere; the
protocol is ERC-20-only.

### `divide-before-multiply` — 4 findings — **accepted (bounded precision loss)**

Three are in `_calculateSeizeAmount` (`:536-564`) and one in `flashLoan`'s premium
accrual. Each is a genuine ordering of `(a * b) / c` followed by a further
multiply, so precision is lost — but the loss is bounded and in the protocol's
favour:

- **Liquidation seize math.** `seizedValueBase`, `debtValueForSeized`, and
  `maxCollateral` each truncate at most 1 wei of *base-currency value* before the
  next multiply. Against 8-decimal Chainlink base pricing, the worst-case error
  is sub-cent on any economically meaningful liquidation, and it rounds the
  seized collateral *down* — the liquidator, not the protocol, absorbs it.
- **Flash-loan premium.** `premium` truncates to the floor of
  `amount * 5 / 10000`. A borrower could flash-loan an amount small enough that
  the premium floors to zero, but the gas cost of the call exceeds the fee
  avoided by orders of magnitude, so this is not economically exploitable.

Reordering to multiply-before-divide would require intermediate values wider than
`uint256` at realistic price and decimal ranges. Aave makes the same trade.

### `incorrect-equality` — 3 findings — **accepted (false positive)**

`_updateState`, `getReserveNormalizedIncome`, and `getReserveNormalizedVariableDebt`
all short-circuit on `last == uint40(block.timestamp)`. This is the standard
"indexes already updated in this block, skip the accrual" guard. It is an
equality against a value the contract itself wrote, not against a balance or a
supply, so the usual objection to strict equality does not apply. If the equality
were ever missed the only consequence would be a redundant accrual of zero
elapsed time — `MathUtils` returns `RAY` for a zero interval.

### `unused-return` — 4 findings — **accepted (intentional)**

Destructured tuples where only some members are needed (`latestRoundData()` for
answer + `updatedAt`, reserve tuples for a single field). Solidity has no syntax
to request a subset.

### `uninitialized-local` — 4 findings — **accepted (false positive)**

Struct-typed locals (`LiquidationVars` and friends) populated field-by-field
before their first read. Solidity zero-initialises them; the detector reports the
absence of an explicit initialiser, not a read-before-write.

---

## Low and Informational

| Detector | Count | Disposition |
|---|---|---|
| `calls-loop` | 18 | Accepted. Health-factor computation iterates the user's reserve list, calling the oracle per asset. The list is bounded by the number of reserves an admin has listed (governance-controlled, single digits), not by anything an attacker can grow. |
| `timestamp` | 16 | Accepted. Interest accrual is a function of elapsed time by definition. Miner timestamp influence is bounded to seconds; the resulting index drift is far below the rounding already present in RAY math. |
| `missing-zero-check` | 4 | Accepted. Admin setters (`setPriceOracle`, `setInterestRateStrategy`, and configurator addresses). A zero address is immediately visible as a total failure on the next interaction rather than a silent compromise, and these are owner-only. |
| `reentrancy-benign` | 3 | Accepted. `nonReentrant`, as above. |
| `naming-convention` | 6 | Accepted. Constructor and setter parameters named after the storage they assign (`_owner`, `_oracle`). |
| `low-level-calls` | 1 | Accepted. `TransferHelper`-style ERC-20 call that tolerates non-standard tokens returning no data. |
| `missing-inheritance` | 1 | Accepted. `PoolConfigurator` implements a subset of an admin interface deliberately; declaring the inheritance would force stubs for functions the contract does not own. |

---

## What static analysis does not cover

The bugs this protocol is most at risk from are all economic, and Slither finds
none of them. These are covered by the test suite instead:

- **Index monotonicity.** `liquidityIndex` and `variableBorrowIndex` must never
  decrease. Asserted in the invariant suite.
- **Reserve solvency.** Total scaled supply × index must always cover
  withdrawable balances. Asserted across randomised multi-actor sequences
  (64 runs × 32 calls, 3 actors).
- **Health-factor correctness at the liquidation boundary.** An off-by-one in the
  weighted-LTV sum lets an underwater position escape liquidation or a healthy
  one get seized. Covered by unit and fuzz tests.
- **Oracle staleness.** `ChainlinkPriceOracle` rejects non-positive answers,
  incomplete rounds, and prices older than a per-feed heartbeat. If a fallback
  oracle is configured, a failing feed falls through to it, so health checks and
  liquidations keep working through a feed outage. Covered in
  `test/ChainlinkOracle.t.sol`.
- **Rounding direction.** Supply shares mint rounded down and burn rounded up;
  debt shares mint rounded up and burn rounded down. Full exits burn the exact
  scaled balance. Fuzzed in `test/Hardening.t.sol`.
- **Repay during a pause.** `repay` is not pausable, because interest keeps
  accruing while the pool is paused. Liquidations stay paused.

## Known improvements

- **No coverage numbers published.** `forge coverage` needs `--ir-minimum` on this
  via-IR project; it currently compiles but has not been wired into CI.
- **Single-block oracle reads.** Prices are read spot from Chainlink with a
  staleness bound. A TWAP or a multi-source median would harden against a
  compromised or lagging feed.
- **Fixed close factor.** Liquidations use a fixed 50% close factor. Aave V3's
  dynamic close factor (100% below a health-factor threshold) handles small
  underwater positions that are otherwise uneconomical to liquidate.
- **No Echidna/Medusa property tests.** Foundry's invariant runner explores
  bounded sequences; a dedicated fuzzer would search deeper.
