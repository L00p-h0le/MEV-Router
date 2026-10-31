# THREAT_MODEL.md: BatchRouter

**Status:** Phase 1 draft, 2026-10-26.
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
| T1 | Classic sandwich of a user's swap | Order inside the batch | One uniform P for every fill, so a round trip inside the batch nets ≤ 0 | None from ordering (attacker pays rounding) | 5 |
| T2 | Sandwiching the `settle` tx | Move the AMM before settle, revert it after | Per-order `minOut` excludes orders the move would hurt; the residual is usually smaller than the gross flow | The attacker can still extract up to the batch's aggregate slippage tolerance on the residual. **Documented residual** | 5 |
| T3 | Settler timing choice | Settle at a block where the AMM is favourable to the settler | `minOut` bounds each order; settle is permissionless, so users can settle themselves | Timing games remain; production fix: settle in a fixed block or a keeper auction | 5 |
| T4 | Free option / non-reveal griefing | Commit both ways, reveal only the side that profits | Bond forfeited on non-reveal; short reveal window | Profitable if the expected gain exceeds the bond; the bond size is a parameter | 5 |
| T5 | Size and direction leak at commit | `tokenIn` and `escrow` are public | `escrow` may exceed `amountIn` (over-escrow hides size); `minOut` stays hidden | Direction always leaks; a whale's over-escrow still signals size | 1 (doc) |
| T6 | Flooding the batch | Fill `MAX_ORDERS_PER_BATCH` with tiny orders to block others | Each slot costs a bond plus gas | The bond is returned on reveal, so the cost is only capital lockup plus gas. Phase 7: minimum order size or a refundable fee | 5, 7 |
| T7 | Gas DoS on settle | Many orders make the exclusion loop O(n²) | `MAX_ORDERS_PER_BATCH` bound | Measure in Phase 7; lower the cap if needed | 7 |
| T8 | Cross-batch sandwich | Trade on the AMM between batch k's settle and k+1's, using knowledge of revealed flow | Reveal happens only after commits close; `minOut` | Revealed flow is public before settle, so the attacker can pre-position. **Analyse in Phase 5** | 5 |
| T9 | Reentrancy | Malicious token or ETH receiver re-enters `claim`/`settle` | `nonReentrant`, CEI, only pair tokens allowed | Low | 7 |
| T10 | Commit copying / replay | Copy someone's hash, or replay across chains or routers | `user`, `chainid` and router address are in the hash | None. Tested in Phase 3 (`test_reveal_copiedCommitCannotBeOpened`, `test_commitHash_isDomainSeparated`) | 3 |
| T11 | Rounding extraction | Many tiny orders farm rounding | Every payout rounds down; pots are physical | Dust accrues to the router, not the attacker | 6 |
| T12 | Stuck funds | settle permanently reverts (for example, an emptied AMM) | Retry later | **Open item for Phase 7:** a timeout refund path | 7 |
| T13 | Weird ERC-20s | Fee-on-transfer, rebasing, missing return value | Balance-delta check at commit; SafeERC20 | Rebasing tokens can still drift after commit; documented as unsupported | 7 |
