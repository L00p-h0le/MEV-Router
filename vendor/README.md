# vendor/

## amm/ConstantProductPair.sol
- **Source:** written fresh on 2026-10-26 for this project. It is **not** copied from another project, and not from Uniswap.
- **Why:** this project builds on the W2 constant-product AMM, but W2 does not exist in `C:\WEB3` (see `instruction.md` §4 and `DECISIONS.md` D-001).
- **Behaviour:**
  - Uniswap-V2-style x·y=k with a 0.3% fee: `dy = dx·997·y / (x·1000 + dx·997)`, rounded down.
  - 1000 minimum-liquidity shares are locked on the first deposit.
  - Reserves are `uint112`.
  - Swap input is measured by balance delta.
- **Swapping for W2 later:** the router only uses `token0()`, `token1()`, `getReservesFor()`, `getAmountOut()` and `swapExactIn()`. Any W2 pair exposing the same functions, or a thin adapter, can replace it.
- **Status:** educational reference, not audited. Do not edit it to suit router bugs; fix the router instead.
