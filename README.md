# W5: MEV-Protected Swap Router

> **Educational reference only. Not audited, not production safe.** Work in progress: Phases 0 to 5 of 8 are done.

| Phase | Status |
|---|---|
| 0 Concepts, 1 Design + spec | Done (`SPEC.md`, `THREAT_MODEL.md`) |
| 2 Attack baseline (`NaiveRouter` + `SandwichAttacker`) | Done, results in §4 |
| 3 Commit/reveal core (`BatchRouter` commit, reveal, forfeit, refund) | Done |
| 4 Netting + settlement (residual swap, uniform price, `minOut` exclusion) | Done, reference table in §4 |
| 5 Attack re-run against `BatchRouter` | Done, before/after in §4 |
| 6 Invariants, 7 Hardening, 8 Write-up | Not started |

`BatchRouter` runs the full batch auction: commit, reveal, forfeit, netting, the residual AMM swap, one uniform price per batch and per-order `minOut` exclusion. Phase 5 found that it removes in-batch ordering games but **not** a sandwich of the `settle` call (§4).

## Layout

```
src/BatchRouter.sol                 commit-reveal batch router with uniform-price settlement
src/NaiveRouter.sol                 baseline direct-swap router (attack target)
vendor/amm/ConstantProductPair.sol  vendored x*y=k pool, 0.3% fee (written fresh, see vendor/README.md)
test/                               unit, fuzz and sandwich-baseline tests, plus the SandwichAttacker harness
script/clearing_reference.py        exact-integer mirror of the clearing math (expected test values)
script/attack_reference.py          exact-integer re-derivation of the Phase 5 attack numbers
SPEC.md, THREAT_MODEL.md            behaviour and threats of the batch router
DECISIONS.md                        dated design decisions
```

## 1. Problem
Sandwich attacks: a searcher reads a pending swap in the public mempool, buys first, lets the victim buy at the worse price, and then sells. On 12 March 2025, a trader swapping about $220k USDC for USDT with unlimited slippage received about $5k (reported by Cointelegraph and Kaiko). The figures are to be re-verified in Phase 8.

## 2. Existing solutions and their flaws
- Slippage limits cap the loss, but the attacker takes up to the cap.
- Private RPCs (Flashbots Protect) rely on off-chain trust.
- CoW Protocol uses solver-based batch auctions, which are complex.

## 3. My approach
An on-chain commit-reveal batch auction in front of a constant-product AMM. Every filled order in a batch clears at one uniform price, and only the net imbalance touches the pool. See `SPEC.md`.

## 4. Results
### Baseline: sandwich on `NaiveRouter` (Phase 2, measured)

These are integer results from `forge test --mc SandwichBaselineTest -vv`. The attacker uses the largest front-run that keeps the victim at `minOut`. Gas and builder tips are not included. Values are truncated to 2 decimals.

Pool 1,000 ETH / 2,000,000 USDC, victim buys ETH, slippage 1%:

| Victim USDC | Victim loss USDC | Front-run USDC | Attacker profit USDC |
|---|---|---|---|
| 1,000 | 9.99 | 10,093.28 | −50.22 |
| 10,000 | 99.99 | 10,115.89 | 39.59 |
| 50,000 | 499.99 | 10,215.16 | 448.41 |
| 100,000 | 999.99 | 10,336.55 | 981.54 |
| 250,000 | 2,499.99 | 10,683.69 | 2,728.17 |
| 500,000 | 4,999.99 | 11,211.17 | 6,128.92 |

Victim 100,000 USDC, slippage 1%, varying pool depth:

| Pool ETH / USDC | Attacker profit USDC |
|---|---|
| 250 / 500,000 | 1,173.81 |
| 1,000 / 2,000,000 | 981.54 |
| 20,000 / 40,000,000 | −208.03 |

With `minOut = 0` and 2M USDC of attacker capital, the 100k victim receives 12.1776 ETH instead of 47.4829 ETH, a loss of 74,353.55 USDC.

### Batch clearing: SPEC §7 reference batches (Phase 4, measured)

These are exact integers from `forge test --mc BatchRouterSettlementTest`. They match `script/clearing_reference.py`. Pool 1,000 ETH / 2,000,000 USDC; P is in USDC per ETH, floored to 6 decimals.

| Sell ETH | Sell USDC | Case | AMM residual | P for ETH sellers | P for USDC sellers |
|---|---|---|---|---|---|
| 10 | 30,000 | USDC excess | 9,841.405404 USDC | 2015.859459 | 2015.859459 |
| 30 | 10,000 | ETH excess | 24.860651606560976461 ETH | 1945.771960 | 1945.771960 |
| 10 | 20,000 | fee band | none (pool untouched) | 2000.000000 | 2000.000000 |
| 10 | 20,050 | fee band | none | 2005.000000 | 2005.000000 |
| 0 | 100,000 | one-sided | 100,000 USDC | — | 2106.018054 (= direct swap, to the wei) |

Both sides of a batch get the same price, and only the net imbalance touches the pool.

### Before/after: the same attacker against `BatchRouter` (Phase 5, measured)

These are integer results from `forge test --mc BatchAttackTest -vv`, re-derived independently by `script/attack_reference.py`. The attacker model is the Phase 2 one, plus three powers: it can call `settle` itself, it reads every revealed `minOut`, and it sees each order's direction and escrow at commit (`DECISIONS.md` D-020). Each cell is victim loss / attacker profit, in USDC.

| Victim USDC | Naive router: sandwich | Batch, T1: sandwich legs inside the batch | Batch, T2: sandwich the `settle` call | Batch, T8: join the victim's side, back-run after settle |
|---|---|---|---|---|
| 1,000 | 9.99 / −50.22 | 0 / ≤ 0 | 9.99 / −50.22 | 9.99 / −110.26 |
| 10,000 | 99.99 / 39.59 | 0 / ≤ 0 | 99.99 / 39.59 | 99.99 / −20.58 |
| 50,000 | 499.99 / 448.41 | 0 / ≤ 0 | 499.99 / 448.41 | 499.99 / 387.66 |
| 100,000 | 999.99 / 981.54 | 0 / ≤ 0 | 999.99 / 981.54 | 999.99 / 920.09 |
| 250,000 | 2,499.99 / 2,728.17 | 0 / ≤ 0 | 2,499.99 / 2,728.17 | 2,499.99 / 2,664.73 |
| 500,000 | 4,999.99 / 6,128.92 | 0 / ≤ 0 | 4,999.99 / 6,128.92 | 4,999.99 / 6,062.49 |

What this shows:
- **Ordering inside a batch no longer pays (T1).** Both legs clear at the same price, so each leg gets at most its input's value at that price, wherever it sits.
- **The `settle` call is still sandwichable (T2).** A batch with flow on one side only is a public swap of the summed input, and every `minOut` is visible after reveal. The attacker settles between its own two pool trades and takes exactly the naive profit, with the same front-run to the base unit.
- **Joining the batch also works (T8).** Joining the victim's side and selling the share afterwards keeps 86–99% of the naive profit at 50k and above.
- **The victim never gets less than its `minOut`.** The router's guarantee equals `NaiveRouter`'s.

The settle sandwich with opposing flow (victim 100,000 USDC at 1%, plus an honest ETH seller with `minOut` 0):

| Opposing ETH | Victim loss vs honest batch | Victim loss vs direct quote | Attacker front-run | Attacker profit |
|---|---|---|---|---|
| 0 | 999.99 | 999.99 | 10,336.55 | 981.54 |
| 10 | 1,980.19 | 999.99 | 20,727.58 | 1,502.56 |
| 25 | 3,414.63 | 999.99 | 36,416.31 | 1,451.44 |
| 40 | 4,807.69 | 999.99 | 52,227.69 | 441.35 |
| 50 | 5,983.71 | 999.99 | 69,052.91 | −815.32 |

Netting gives the victim a better price than the direct quote its `minOut` was set from. The attack takes that surplus as well: part goes to the attacker, and part to the counterparty who accepts any price. Measured against the direct quote, the victim still loses at most its 1% tolerance.

Other attacks:
- **Withheld reveals (T4).** The attacker commits 8 rungs of 3,000 USDC, reads the victim's `minOut` once it is revealed, and reveals 7 rungs. It earns 908.42 USDC for one forfeited 0.01 ETH bond.
- **Flooding (T6).** 100 orders of 1 wei WETH fill the batch, so the victim waits one batch. Every order is refunded, so the attack costs only gas (about 9.6M in total).

**Mitigation proposed for Phase 7 (not built, D-021):** bound the settle price by a time-weighted average price (TWAP) over the reveal window.

## 5. Limitations and production changes
*Pending. See `THREAT_MODEL.md` for the current list.*

## Run it

Prerequisites: [Foundry](https://getfoundry.sh) (tested with forge 1.7.1) and git.

```shell
# only if lib/ is missing (fresh clone):
forge install foundry-rs/forge-std@v1.17.0 --no-git --shallow
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0 --no-git --shallow
forge build
forge test -vv
forge test --mc SandwichBaselineTest -vv   # prints the Phase 2 baseline tables
forge test --mc BatchRouterSettlementTest -vv   # Phase 4 clearing tests (prints worst-case settle gas)
python script/clearing_reference.py        # recomputes the Phase 4 expected values
forge test --mc BatchAttackTest -vv        # Phase 5 before/after tables
python script/attack_reference.py          # recomputes the Phase 5 numbers
forge fmt --check
forge fmt --check vendor   # vendor/ is outside forge fmt's default paths
```
