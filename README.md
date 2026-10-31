# W5: MEV-Protected Swap Router

> **Educational reference only. Not audited, not production safe.** Work in progress: Phases 0 to 3 of 8 are done.

| Phase | Status |
|---|---|
| 0 Concepts, 1 Design + spec | Done (`SPEC.md`, `THREAT_MODEL.md`) |
| 2 Attack baseline (`NaiveRouter` + `SandwichAttacker`) | Done, results in §4 |
| 3 Commit/reveal core (`BatchRouter` commit, reveal, forfeit, refund) | Done |
| 4 Netting + settlement | Not started |
| 5 Attack re-run, 6 Invariants, 7 Hardening, 8 Write-up | Not started |

`BatchRouter` has commit, reveal, forfeits and refunds. It does not clear trades yet: until Phase 4, a settled batch refunds every revealed order in full (`SPEC.md` §6.1).

## Layout

```
src/BatchRouter.sol                 commit-reveal batch router (Phase 3: no clearing yet)
src/NaiveRouter.sol                 baseline direct-swap router (attack target)
vendor/amm/ConstantProductPair.sol  vendored x*y=k pool, 0.3% fee (written fresh, see vendor/README.md)
test/                               unit, fuzz and sandwich-baseline tests, plus the SandwichAttacker harness
SPEC.md, THREAT_MODEL.md            behaviour and threats of the planned batch router
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

*Pending (Phase 5): the same attacker against the batch router.*

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
forge fmt --check
forge fmt --check vendor   # vendor/ is outside forge fmt's default paths
```
