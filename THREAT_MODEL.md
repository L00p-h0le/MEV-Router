# THREAT_MODEL.md: BatchRouter

**Status:** Phase 1 draft, 2026-10-26. Phase 5 (2026-11-01): T1, T2, T4, T6 and T8 measured in `test/BatchAttack.t.sol`; results in `README.md` §4 and D-021.
- Phase 5 turns each threat into a test (attack on the naive router vs the batch router).
- Phase 7 closes or documents the open items.

## Assets
- Users' escrowed tokens and ETH bonds.
- The fairness of the clearing price (no order position advantage).
- The AMM reserves (only through the residual swap).

## Actors
- **Honest users**
- **Searchers / attackers:** see the mempool, can bundle transactions, and can trade on the AMM directly.
- **Settler:** anyone; may also be the attacker.
- **Block builder:** controls ordering inside a block.

## Threats

| # | Threat | Vector | Mitigation in the design | Residual risk | Test phase |
|---|---|---|---|---|---|
| T1 | Classic sandwich of a user's swap | Order inside the batch | One uniform P for every fill, so a round trip inside the batch nets ≤ 0 | **Measured: removed.** Each attacker leg receives at most its input at P (unit test + 256-run fuzz); moving the legs around the victim changes no payout | 5 |
| T2 | Sandwiching the `settle` tx | Move the AMM before settle, revert it after; the attacker can settle itself | Per-order `minOut` | **Measured: not mitigated.** One-sided batch = the naive sandwich to the base unit (981.546959 USDC from a 100k victim at 1%). Opposing flow makes it worse versus the honest batch, because the netting surplus becomes slack (1,502.56 USDC at 10 ETH of counterflow). Victim never below `minOut`. **Open: D-021 recommends a TWAP price band (Phase 7, needs approval)** | 5, 7 |
| T3 | Settler timing choice | Settle at a block where the AMM is favourable to the settler | `minOut` bounds each order; settle is permissionless, so users can settle themselves | Timing games remain; production fix: settle in a fixed block or a keeper auction | 5 |
| T4 | Free option / non-reveal griefing | Commit several orders, reveal only what pays after seeing others' reveals | Bond forfeited on non-reveal; short reveal window | **Measured:** a ladder of 8 × 3,000 USDC, 7 revealed after reading the victim's `minOut`, earns 908.42 USDC for one 0.01 ETH bond. The bond prices the option far below its value at this size | 5, 7 |
| T5 | Size and direction leak at commit | `tokenIn` and `escrow` are public | `escrow` may exceed `amountIn` (over-escrow hides size); `minOut` stays hidden | Direction always leaks; a whale's over-escrow still signals size | 1 (doc) |
| T6 | Flooding the batch | Fill `MAX_ORDERS_PER_BATCH` with tiny orders to block others | Each slot costs a bond plus gas | **Measured:** 100 orders of 1 wei WETH block the batch; the victim waits one batch (C blocks). Revealing everything refunds every wei and bond (each order is excluded, D-016), so the cost is gas: 8,857,000 for the commits and 766,522 for the reveals. Spam moves the price only by its own size. Phase 7: minimum order size or a non-refundable fee | 5, 7 |
| T7 | Gas DoS on settle | Many orders make the exclusion loop O(n²) | `MAX_ORDERS_PER_BATCH` bound; the loop runs over a memory copy (D-019) | Phase 4 measured about 10.84M gas for a 100-order worst case (`test_gas_fullBatchWorstCaseExclusion`). Phase 7: snapshot it and lower the cap if needed | 7 |
| T8 | Cross-batch / join-and-back-run | Join the victim's side in the same batch (direction and size leak at commit), sell the share on the AMM after settle | Reveal happens only after commits close; `minOut` | **Measured: largely not mitigated.** Keeps 920.10 of the 981.55 naive profit at 100k (94%); 86% at 50k, 98–99% at 250k–500k. Same D-021 mitigation | 5, 7 |
| T9 | Reentrancy | Malicious token or ETH receiver re-enters `claim`/`settle` | `nonReentrant`, CEI, only pair tokens allowed | Low | 7 |
| T10 | Commit copying / replay | Copy someone's hash, or replay across chains or routers | `user`, `chainid` and router address are in the hash | None. Tested in Phase 3 (`test_reveal_copiedCommitCannotBeOpened`, `test_commitHash_isDomainSeparated`) | 3 |
| T11 | Rounding extraction | Many tiny orders farm rounding | Every payout rounds down; pots are physical | Dust accrues to the router, not the attacker | 6 |
| T12 | Stuck funds | settle permanently reverts (for example a side total above uint128, D-018) | Retry later; an unseeded pool no longer reverts, it refunds everyone (D-017) | **Open item for Phase 7:** a timeout refund path | 7 |
| T13 | Weird ERC-20s | Fee-on-transfer, rebasing, missing return value | Balance-delta check at commit; SafeERC20 | Rebasing tokens can still drift after commit; documented as unsupported | 7 |
