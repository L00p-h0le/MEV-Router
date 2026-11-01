"""Exact-integer re-derivation of the Phase 5 attack numbers in test/BatchAttack.t.sol, independent of Solidity.
Uses the clearing mirror in clearing_reference.py. Pool 1,000 ETH / 2,000,000 USDC, victim buys ETH, 1% slippage.

Run: python script/attack_reference.py
"""

import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location("clearing", Path(__file__).with_name("clearing_reference.py"))
clearing = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(clearing)

E, U = clearing.E, clearing.U
A0, B0 = clearing.RESERVE_A, clearing.RESERVE_B
amount_out = clearing.amount_out
SLIPPAGE_BPS = 100
SEARCH_CAP = B0


def min_out(victim_in: int) -> int:
    return amount_out(victim_in, B0, A0) * (10_000 - SLIPPAGE_BPS) // 10_000


def largest(ok) -> int:
    """Largest x in [0, SEARCH_CAP] with ok(x), for ok monotone decreasing (same search as the tests)."""
    lo, hi = 0, SEARCH_CAP
    while lo < hi:
        mid = lo + (hi - lo + 1) // 2
        if ok(mid):
            lo = mid
        else:
            hi = mid - 1
    return lo


def join_and_back_run(victim_in: int) -> tuple[int, int, int]:
    """T8: (joined USDC, attacker profit USDC, victim loss USDC)."""
    m = min_out(victim_in)

    def share(joined: int) -> tuple[int, int]:
        pot = amount_out(victim_in + joined, B0, A0)
        return victim_in * pot // (victim_in + joined), pot

    joined = largest(lambda j: share(j)[0] >= m)
    victim_out, pot = share(joined)
    attacker_eth = joined * pot // (victim_in + joined)
    back = amount_out(attacker_eth, A0 - pot, B0 + victim_in + joined)
    fair = amount_out(victim_in, B0, A0)
    return joined, back - joined, (fair - victim_out) * victim_in // fair


def victim_payout(victim_in: int, counter_eth: int, a: int, b: int) -> int:
    """Victim ETH from a batch [victim buys with USDC, honest seller sells counter_eth at minOut 0] at reserves (a, b).
    The honest seller never fails its limit (except at a zero payout, not reached here), so no exclusion round."""
    _, _, _, pot_a, _ = clearing.clear(counter_eth, victim_in, a, b)
    return victim_in * pot_a // victim_in


def settle_sandwich(victim_in: int, counter_eth: int) -> tuple[int, int, int]:
    """T2: (front-run USDC, attacker profit USDC, victim loss USDC vs the no-attack batch)."""
    m = min_out(victim_in)

    def after_front_run(f: int) -> tuple[int, int, int]:
        bought = amount_out(f, B0, A0) if f else 0
        return bought, A0 - bought, B0 + f

    def survives(f: int) -> bool:
        _, a, b = after_front_run(f)
        return victim_payout(victim_in, counter_eth, a, b) >= m

    f = largest(survives)
    bought, a, b = after_front_run(f)
    case, r, out, pot_a, pot_b = clearing.clear(counter_eth, victim_in, a, b)
    if case == "B excess":
        a, b = a - out, b + r
    elif case == "A excess":
        a, b = a + r, b - out
    back = amount_out(bought, a, b) if bought else 0
    fair = victim_payout(victim_in, counter_eth, A0, B0)
    got = victim_payout(victim_in, counter_eth, *after_front_run(f)[1:])
    return f, back - f, (fair - got) * victim_in // fair


def main() -> None:
    print("T8 join + back-run (victim loss / attacker profit, USDC):")
    for size in [1_000, 10_000, 50_000, 100_000, 250_000, 500_000]:
        joined, profit, loss = join_and_back_run(size * U)
        print(f"  victim {size:>7}: joined {joined}, profit {profit}, victim loss {loss}")
    print("T2 settle sandwich, victim 100,000 USDC, honest ETH seller at minOut 0:")
    for eth in [0, 10, 25, 40, 50]:
        f, profit, loss = settle_sandwich(100_000 * U, eth * E)
        print(f"  counterflow {eth:>2} ETH: front-run {f}, profit {profit}, victim loss {loss}")


if __name__ == "__main__":
    main()
