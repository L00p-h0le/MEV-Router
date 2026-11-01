# DECISIONS.md

A dated log of decisions, ADR style. Each entry gives the decision, the reason, and the alternatives rejected. Entries marked **(review)** are defaults picked without blocking on the user. They are listed in `STATUS.md` under "Decisions to review".

## D-001 (2026-10-26): Vendor a fresh constant-product AMM
- **Decision:** write a minimal Uniswap-V2-style x·y=k pair (0.3% fee) in `vendor/amm/`. Do not depend on W2.
- **Why:** the W2 AMM does not exist in `C:\WEB3`, and `instruction.md` §4 says to write a fresh one at Phase 1. It can be swapped for the user's W2 later.
- **Rejected:** importing the Uniswap V2 sources. Their solc 0.5/0.6 pragma clashes with ^0.8, and they are much more code than we need.

## D-002 (2026-10-26): Sandwich numbers come from a script, not hand calculation (Phase 0)
- **Decision:** the Phase 0 numbers come from a float64 simulation of the V2 formula. Phase 2 re-derives them in Foundry with integer math.
- **Why:** this follows the "never fabricate numbers" rule, and it makes the numbers reproducible.
- **Rejected:** illustrative round numbers, which cannot be checked.

## D-003 (2026-10-26): Do Phases 0 and 1 in one run, then stop for review (review)
- **Why:** the SPEC decisions (clearing-price math, exclusion rule) shape every later phase, so the user should see them before any router code is written.

## D-004 (2026-10-26): Phase 1 design defaults (review)

| Topic | Decision | Rejected alternative and why |
|---|---|---|
| Market scope | One router instance per token pair, with orders A→B or B→A | Multi-pair router: more complexity, adds nothing to the lesson |
| Windows | Block-number based. Commit N blocks, then reveal M blocks. Both immutable at deploy | Timestamps: easier for validators to manipulate |
| Deposit | A fixed ETH bond (`msg.value`), immutable | Token-denominated bond: needs a price for the bond |
| Forfeit recipient | An immutable `treasury` address | Redistribution to revealers: new incentive edge cases |
| Uniform price | Both sides clear at one price P. The residual is sized so that per-token inflows equal outflows (closed form for x·y=k, see SPEC) | Spot for the matched part plus the AMM price for the residual: two prices, so not uniform |
| minOut failure | Exclude the order with the tightest violated limit, recompute, repeat (bounded by the order count), and refund the excluded orders | Reverting the whole batch: one order could grief everyone |
| Settle | Permissionless, callable once after the reveal window | Owner-only settler: a censorship point |
| Payout | Pull-based `claim()` | Push transfers inside settle: reentrancy risk and unbounded gas |
| Loop bound | `MAX_ORDERS_PER_BATCH = 100`, tuned in Phase 7 | Unbounded loops |
| Rounding | Payouts round down. Dust stays in the router and is tracked, never over-paid | Round to nearest: can pay out more than came in |

## D-005 (2026-10-26): `commit` takes `tokenIn` and `escrow`; the hash adds chainid and router address (review)
- **Decision:**
  - `commit(bytes32 hash, address tokenIn, uint256 escrow)` instead of the brief's `commit(bytes32 hash)`.
  - `escrow ≥ amountIn` is allowed, so users can over-escrow to hide their size.
  - The hash preimage gains `block.chainid` and `address(this)`.
- **Why:** the router cannot escrow an amount it does not know. Over-escrow is a one-comparison mitigation for threat T5 (size leak). Domain separation is required by `security.md` (replay protection).
- **Rejected:**
  - Escrowing at reveal: non-revealers would then risk nothing but the bond, and a revealed order could be unfunded at settle.
  - Exact-escrow only: it leaks size for free.

## D-006 (2026-10-26): Permissionless reveal, owner-only claim (review)
- **Decision:** anyone holding the preimage may `reveal`, for example a keeper the user hands the salt to. Only `order.user` may `claim`.
- **Why:** the hash binds `user`, so a third-party reveal cannot redirect funds, and it reduces non-reveals caused by forgetting. Owner-only claim avoids pushing ETH or tokens to a user at an unexpected time.
- **Rejected:** owner-only reveal (more forfeits, no gain). Permissionless claim (it is griefable through the ETH refund).

## D-007 (2026-10-26): Uniform-price residual uses the closed form, checked with an exact-integer script
- **Decision:** `r_A = (997·b·XA − 1000·a·XB) / (997·(b + XB))` and its symmetric version. Inside the fee band, P = XB/XA with no AMM call. See SPEC §7.
- **Why:** it makes the AMM's average price on the residual equal the matched price, so both sides get exactly the same P. It is O(1), so no iterative solver is needed. A BigInt script confirmed equal prices on both sides to 6 decimals, and that a one-sided batch equals a direct swap.
- **Rejected:**
  - Netting at spot plus charging the residual's impact to one side: two prices.
  - A binary search for P: more gas, and rounding drift.

## D-008 (2026-10-26): Position-independent exclusion rule (review)
- **Decision:** each round, per side, exclude *all* violators that share the strictest limit ratio. Repeat for at most `orderCount` rounds.
- **Why:** removing the strictest first keeps the most fills, and removing ties together means no index-based tie-break, so order position never matters.
- **Rejected:**
  - Excluding all violators at once: over-excludes orders that would pass after recomputing.
  - Tie-break by index: position would matter.
  - Reverting the batch: griefing.

## D-009 (2026-10-26): Toolchain pins
- **Decision:** solc 0.8.28 (`evm_version = cancun`), forge-std 1.17.0 (version from `lib/forge-std/package.json`; installed `--no-git`, so there is no commit SHA), and OpenZeppelin Contracts v5.4.0. Fuzz runs 256 with a fixed seed; invariant runs 256 at depth 50.
- **Why:** pinned and reproducible. OZ 5.x requires ^0.8.20. The fixed seed keeps fuzz runs deterministic (`standards.md`).
- **Rejected:** floating `latest`.

## D-010 (2026-10-27): `NaiveRouter` mirrors the Uniswap V2 router for one pair (review)
- **Decision:** `swapExactIn(tokenIn, amountIn, minOut, to, deadline)` pulls the input to itself, measures the balance increase, approves exactly that to the pair, and lets the pair enforce `minOut`. `deadline` is a `block.timestamp`, as in V2.
- **Why:** the baseline should be the thing real users actually call, so the victim's only protection is `minOut`, as in production. A timestamp deadline matches the V2 interface users know, and it is a coarse expiry, not a security clock, so a few seconds of proposer skew does not matter.
- **Rejected:**
  - Letting the victim call the pair directly: this hides the router layer that Phase 5 compares against.
  - A block-number deadline: consistent with D-004, but it departs from the V2 convention for no security gain.
  - No deadline: a stale tx could execute much later at a bad price.

## D-011 (2026-10-27): Attacker model for the baseline (review)
- **Decision:**
  - The `SandwichAttacker` harness picks the **largest** front-run that keeps the victim at or above `minOut`. It finds it by an exact integer binary search over the pair's own `getAmountOut`.
  - The test contract plays the builder: it orders [front-run, victim, back-run] in one transaction, which models an atomic bundle.
  - The attacker's capital is unlimited (`type(uint112).max`), which models a flash loan.
  - Profit is reported even when negative, to match the Phase 0 tables. Gas and builder tips are not modelled.
- **Why:**
  - This is the same strategy as the Phase 0 model, so the two can be compared row by row.
  - Using the pair's formula makes the prediction match execution to the wei, and a test asserts that.
  - Capital is not a real constraint for searchers.
- **Rejected:**
  - A profit-maximising (possibly interior) front-run. It is not needed to show the victim's loss, which is set by `minOut` either way. In the deep pool, a fuzz test shows that no size is profitable. Whether the boundary is profit-maximising in general is left as LEARN practice test 1.
  - The float closed form, which would not match execution exactly.
  - An Anvil script with real mempool ordering: more moving parts, same numbers.

## D-012 (2026-10-27): How victim loss is measured
- **Decision:** `victimLoss = (fairOut − victimOut) · victimIn / fairOut`. This is the lost output valued at the victim's own no-attack average price, in `tokenIn` units, the same as Phase 0.
- **Why:** it answers "how much input did the sandwich cost you", and it is independent of where the price ends up after the back-run.
- **Rejected:** valuing at spot or at the post-attack price. Both depend on the attacker's own trades.

## D-013 (2026-11-01): Phase 3 settles without clearing; revealed orders are refunded in full (review). **Superseded in Phase 4** (the interim branch is removed; see D-016 to D-019)
- **Decision:**
  - In Phase 3, `settle` forfeits unrevealed orders and marks the batch settled. Revealed orders stay `Revealed`.
  - `claim` on a `Revealed` order returns its whole escrow plus the bond. This is the same payout an `Excluded` order gets.
  - `settle` emits `OrderForfeited(batchId, index)` per forfeit, a new event next to `OrderExcluded`.
  - Phase 4 replaces the interim branch with netting, the residual swap and the uniform price.
- **Why:**
  - `instruction.md` puts refunds in Phase 3 and netting in Phase 4. A forfeited order's escrow can only be refunded after settle, so Phase 3 needs a settle.
  - Making it a full refund keeps every Phase 3 batch fund-safe; nothing is ever stuck.
  - Without the event, a forfeit could only be detected by polling order status.
- **Rejected:**
  - Writing all of settle now: it jumps ahead of the phase.
  - A settle that reverts while revealed orders exist: their funds would be locked until Phase 4.
  - Marking revealed orders `Excluded` in Phase 3: that would give the status a meaning it does not have (it means "failed `minOut`").

## D-014 (2026-11-01): Test parameters: bond 0.01 ETH, C = 10 blocks, R = 5 blocks (review)
- **Decision:** the unit tests use `bond = 0.01 ether`, `commitBlocks = 10` and `revealBlocks = 5`, deployed at block 1,000. Deploy values stay open until Phase 8.
- **Why:**
  - The windows are short enough that tests can roll across several batches cheaply.
  - R < C exercises the overlap where batch k+1 commits while batch k reveals.
  - The bond is non-trivial, but small next to the test amounts.
- **Rejected:** C = R. It hides off-by-one bugs that mix up the two lengths.

## D-015 (2026-11-01): Small Phase 3 interface choices (review)
- **Decision:**
  - A zero `bond` in the constructor reverts with `ZeroAmount`.
  - `withdrawForfeits` reverts with `ZeroAmount` when nothing is owed.
  - A revealed `minOut` above `uint128` is stored saturated, not rejected.
  - Errors carry their arguments, e.g. `WrongBond(sent, required)` and `NotInRevealWindow(batchId, block)`.
  - Reveal is not `nonReentrant`: it makes no external calls.
- **Why:**
  - Saturation keeps the meaning of the order (unfillable, so excluded and refunded). Rejecting it would make the order unrevealable, and the user would lose the bond.
  - Errors with arguments make test assertions exact and help debugging.
  - The `ZeroAmount` revert avoids an event that moves nothing.
- **Rejected:**
  - A new `InvalidBond` error: one more error for the same meaning.
  - A silent no-op withdrawal.

## D-016 (2026-11-01): A fill must pay at least 1 base unit; `minOut = 0` counts as 1 (review)
- **Decision:** at settle, an order is satisfied only if `out_i ≥ max(minOut_i, 1)`. The same effective limit is used when ranking violators by limit ratio.
- **Why:** a filled order with `out_i = 0` gives up its whole input for nothing. Its input then sits in the opposite pot with no one entitled to it, so it is stuck in the router forever. This happens in practice for tiny orders: 1 wei of WETH quotes 0 USDC (`test_exclusion_zeroPayoutNeverFills`). Treating 0 as 1 keeps the exclusion rule unchanged and turns that case into an ordinary refund.
- **Rejected:**
  - Rejecting `minOut = 0` at reveal: the user would lose the bond for a harmless parameter choice.
  - A minimum order size: it does not cover every rounding-to-zero case, and it is a Phase 7 topic (T6).
  - Allowing zero fills: it silently burns user funds.

## D-017 (2026-11-01): An unseeded pool fills nothing (review)
- **Decision:** if either pair reserve is 0 at settle, every revealed order is `Excluded` and refunded in full.
- **Why:** with zero reserves, both residual tests (`997·b·XA > 1000·a·XB` and its mirror) are false. So every batch falls into the "fee band" and clears at XB/XA with no reference price at all. Only `minOut` would protect users, and a `minOut` of 0 would be filled at any ratio. The Phase 3 suite runs against an unseeded pair, which is how this case showed up.
- **Rejected:**
  - Reverting settle: funds would be locked until someone seeds the pool.
  - Clearing at XB/XA anyway: users could be matched at an arbitrary price.

## D-018 (2026-11-01): A side total or pot above `uint128` reverts settle with `AmountTooLarge` (review)
- **Decision:** each order is capped at `uint128` at commit, but up to 100 of them can sum to more. `_price` reverts if `XA` or `XB` exceeds `type(uint128).max`, and the stored pots are range-checked.
- **Why:** the cap keeps every product in the closed form below 2^256 (`2^10 · 2^112 · 2^128`), so plain checked arithmetic is enough. It also lets the totals be stored in the existing packed `uint128` fields. Reaching it needs more than 3.4·10^38 base units of one token in one batch, which a real token cannot supply. The pair would also revert on such a residual anyway (`uint112` reserves).
- **Rejected:**
  - Widening the batch fields to `uint256`: about 2 more storage slots per settle, for a case only a mock token can reach.
  - Excluding orders until the total fits: more code and a new ordering question, for an unreachable case.
- **Known consequence:** settle can revert permanently for such a batch, which locks funds. This is the existing open item T12 (timeout refund, Phase 7).

## D-019 (2026-11-01): Clearing runs over a memory copy; `previewOut` simulates settling now
- **Decision:**
  - `_clear` copies each order (`amountIn`, `minOut`, direction) into a memory array once and runs the price and exclude loop entirely over memory.
  - `settle` and `previewOut` share that function.
  - Before settle, `previewOut` reports the result of settling at the current block, with the orders revealed so far.
  - The fee constants 997/1000 are local constants that must equal the pair's. A one-order batch that equals a direct swap to the wei is the test that pins them.
- **Why:**
  - The exclusion loop is O(rounds × orders). Re-reading storage each round would cost several warm SLOADs per order per round.
  - Measured worst case with a memory copy: about 10.84M gas for a full 100-order batch that needs about 50 rounds (`test_gas_fullBatchWorstCaseExclusion`).
  - One shared function means the preview cannot drift from settle.
- **Rejected:**
  - Reading the fee from the pair at every price step: an external call per round for a value that never changes.
  - A `previewOut` that only works after settle: clients need a pre-settle estimate to choose `minOut`.
