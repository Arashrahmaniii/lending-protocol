# DeFi Lending Protocol

[![CI](https://github.com/Arashrahmaniii/lending-protocol/actions/workflows/ci.yml/badge.svg)](../../actions)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?logo=solidity)](https://soliditylang.org)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://getfoundry.sh)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An over-collateralised, multi-asset money market in the style of **Aave**, built from scratch in Solidity. Users supply assets to earn interest, borrow against their collateral, take **flash loans**, delegate borrowing power, and unhealthy positions are **liquidated** by keepers for a bonus.

Verified by **48 tests**: unit, fuzz (property-based), and stateful **invariant** testing with a randomized multi-actor handler.

> ⚠️ Reference implementation for demonstration purposes — not audited. Do not use with real funds.

## Highlights

| | |
|---|---|
| 🏦 **Multi-asset reserves** | Per-asset aToken + debt token, risk params, interest curve, supply/borrow caps |
| 📈 **Scaled-balance interest** | O(1) interest accrual via cumulative RAY indexes — no per-user loops, ever |
| 📐 **Kinked rate model** | Two-slope utilisation curve; rates spike past optimal utilisation to protect liquidity |
| ❤️ **Health factor engine** | Weighted LTV / liquidation thresholds across any mix of collateral & debt |
| ⚡ **Liquidations** | 50% close factor, liquidation bonus, receive collateral as aTokens or underlying |
| 💸 **Flash loans** | Aave-style `executeOperation` callback, 0.09% premium streamed to suppliers via the liquidity index |
| 🤝 **Credit delegation** | Approve another address to borrow against your collateral (uncollateralised lending building block) |
| 🔮 **Chainlink oracle adapter** | Positive-answer + heartbeat staleness validation, per-feed config, fallback oracle on missing *or failing* feeds |
| 🛡️ **Safety rails** | Reentrancy guards, pause guardian (repay stays open), per-reserve freeze, validated risk configs, pool-only mint/burn, protocol-favouring rounding |

## Architecture

```
                            ┌──────────────────────┐
                            │ ChainlinkPriceOracle │  heartbeat + staleness checks,
                            │  (or PriceOracle)    │  feeds normalised to 1e18
                            └──────────┬───────────┘
                                       │ getAssetPrice()
  deposit / withdraw / borrow /  ┌─────▼──────────┐  calculateInterestRates()
  repay / flashLoan / liquidate ►│  LendingPool   │◄───────────────────────────────┐
                                 │ indexes · risk │                                │
                                 │ · liquidation  │               ┌────────────────┴────────────┐
                                 └──┬──────────┬──┘               │ DefaultInterestRateStrategy │
                        mint/burn   │          │  mint/burn       │  (kinked two-slope curve)   │
                     ┌──────────────▼──┐   ┌───▼───────────────┐  └─────────────────────────────┘
                     │     AToken      │   │ VariableDebtToken │
                     │ transferable,   │   │ non-transferable, │
                     │ HF-checked;     │   │ credit delegation │
                     │ holds the vault │   │                   │
                     └─────────────────┘   └───────────────────┘
                              ▲
                              │ deploys aToken/debtToken,
                              │ validates risk params,
                              │ then registers via
                              │ pool.initReserve(...)
                     ┌────────┴─────────┐
                     │ PoolConfigurator │  admin-only reserve listing & config
                     └──────────────────┘
```

| Contract | Responsibility |
|---|---|
| [`LendingPool`](src/LendingPool.sol) | User actions, index/rate updates, health factors, liquidations, flash loans |
| [`PoolConfigurator`](src/PoolConfigurator.sol) | Reserve listing (deploys aToken/debtToken), risk-parameter validation & updates |
| [`AToken`](src/tokens/AToken.sol) | Interest-bearing receipt token; transfers finalized by the pool with a health-factor check |
| [`VariableDebtToken`](src/tokens/VariableDebtToken.sol) | Scaled debt tracking + credit delegation allowances |
| [`DefaultInterestRateStrategy`](src/DefaultInterestRateStrategy.sol) | Utilisation → (supply APR, borrow APR) |
| [`ChainlinkPriceOracle`](src/ChainlinkPriceOracle.sol) | Chainlink adapter: answer/staleness validation, decimal normalisation, fallback |
| [`WadRayMath`](src/libraries/WadRayMath.sol) / [`MathUtils`](src/libraries/MathUtils.sol) | Fixed-point math; linear (supply) & binomially-compounded (borrow) interest |

**Why a separate `PoolConfigurator`?** Deploying `AToken`/`VariableDebtToken` from inside `LendingPool.initReserve` embeds both contracts' full creation bytecode into `LendingPool` itself — that alone pushed it past the **EIP-170 24,576-byte** contract size limit (Ethereum refuses to deploy oversized contracts). Splitting reserve administration into its own contract — the same pattern Aave uses — dropped `LendingPool` from 27,545 to **16,074 bytes**, restoring 8.5KB of headroom, while keeping every user-facing hot path untouched.

## The math

**Scaled balances.** Depositing `amount` mints `amount / liquidityIndex` scaled units; the visible balance is `scaled × index`. Interest is paid by growing the index — every holder's balance grows proportionally with zero per-user state.

**Rounding.** Every conversion between underlying and scaled units rounds in the protocol's favour: supply shares are minted rounded down and burned rounded up, and debt shares are minted rounded up and burned rounded down. So nobody can withdraw more than they deposited or repay less than they owe, even by a wei. A full exit (`type(uint256).max`) burns the exact scaled balance, so it always clears the position.

**Index updates** (on every interaction, per reserve):

```
liquidityIndex  *= 1 + supplyRate · Δt/year                     (linear)
borrowIndex     *= compound(borrowRate, Δt)                     (3rd-order binomial)
```

**Rate curve** (`U` = utilisation):

```
U ≤ U*  :  borrowRate = base + slope1 · U/U*
U > U*  :  borrowRate = base + slope1 + slope2 · (U−U*)/(1−U*)
supplyRate = borrowRate · U · (1 − reserveFactor)
```

**Health factor** — liquidatable below 1:

```
HF = Σ(collateralᵢ · priceᵢ · liquidationThresholdᵢ) / Σ(debtⱼ · priceⱼ)
```

**Liquidation** — the seizure amount includes the bonus and is capped by the user's collateral (the covered debt scales back down if collateral binds):

```
collateralSeized = debtCovered · debtPrice · liquidationBonus / collateralPrice
```

A subtle property surfaced by the fuzz suite: once collateral value falls *below* `debt × bonus`, paying the liquidation bonus mathematically **worsens** the health factor — true of Aave as well, and the reason prompt liquidation (and sane threshold × bonus configs, which `initReserve` enforces) matters.

## Testing

```bash
forge test          # 48 tests: 7 suites
forge build --sizes # verify every contract fits under EIP-170 (CI-enforced)
```

- **Unit** — full lifecycle: deposit, LTV-limited borrow, interest accrual, repay, both liquidation modes, treasury fees
- **Security-focused** — borrowing against a stranger's collateral, reentrancy via flash-loan callback, aToken transfer draining collateral, pause/freeze bypasses, config foot-guns
- **Fuzz** (256 runs each) — lossless deposit/withdraw round-trip, borrow never exceeds LTV, interest monotonicity, liquidation improves HF, rounding never favours the user (repay, borrow, supply)
- **Invariant** (64 runs × 32-call sequences, 3 actors) — reserve solvency (`cash + debt ≥ owed to suppliers`), scaled-supply consistency, no user action leaves its own position under HF 1
- **Hardening** — full exits clear positions exactly, repay works while paused, interest alone can make a position liquidatable, dust debt can be liquidated

### Self-review (October 2026)

A later attacker-style review of this code found no High or Medium issues, but did find these Low ones, each now fixed with a regression test that fails on the old code:

| Issue | Fix |
|---|---|
| Scaled-unit rounding was half-up, so some operations rounded in the user's favour (sub-wei per call) | Directional rounding in `AToken` / `VariableDebtToken` |
| Pausing blocked `repay` while interest kept accruing | `repay` is no longer pausable |
| A stale or invalid Chainlink feed reverted every health check, even with a fallback configured | Fall back on failing feeds |
| Debt below 2 wei could never be liquidated (50% close factor rounded to 0) | Dust debt can be closed in full |
| The invariant "no unhealthy positions without price moves" ignored interest and failed on some seeds | Replaced with "no user action leaves its own position under HF 1", plus a test that interest-driven positions are liquidatable |

Slither runs in CI. [`SECURITY.md`](SECURITY.md) records the full baseline — 76
findings, each either fixed or justified in writing — and documents the economic
properties static analysis cannot reach, along with the tests that cover them.

## Getting started

```bash
git clone --recursive https://github.com/Arashrahmaniii/lending-protocol.git && cd lending-protocol
forge build
forge test -vv

# local deployment (two demo reserves wired to mock Chainlink feeds)
anvil &
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --private-key <ANVIL_KEY>
```

## Design decisions & trade-offs

- **Conservative flash loans.** The reentrancy guard stays active during the flash-loan callback, so receivers cannot re-enter the pool (e.g. to self-liquidate). This trades composability for a smaller attack surface — Aave chooses the opposite; both are defensible and the change is one modifier.
- **Debt is non-transferable**; ERC20 `approve` on the debt token reverts. Borrowing power moves only through explicit `approveDelegation`.
- **Close factor is a constant 50%** rather than configurable, following Aave v2 (dust debt excepted, see above). Full-position liquidation for deeply underwater accounts (Aave v3.1 behaviour) is a natural extension.
- **No bad-debt socialisation.** If collateral runs out before the debt does, the remaining debt stays on the books. Aave v3.3 burns it against the reserve; that is a natural extension.
- **Oracle prices are WAD-normalised** at the adapter boundary so the pool core never deals with feed decimals.

## What I'd add next

Isolation mode & e-mode, stable-rate borrowing, ERC-4626 wrapper vaults, governance timelock + role-based access (the admin is currently a single EOA), gas golfing pass (bitmap-packed reserve config), and a formal verification pass on `WadRayMath`/`MathUtils` with Halmos or Certora.

## License

[MIT](LICENSE)
