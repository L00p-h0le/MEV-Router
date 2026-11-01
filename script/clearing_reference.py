"""Exact-integer mirror of BatchRouter._price (SPEC.md §7), used to derive the expected values in
test/BatchRouterSettlement.t.sol. Pool: 1,000 ETH (18 decimals) / 2,000,000 USDC (6 decimals).

Run: python script/clearing_reference.py
"""

E, U = 10**18, 10**6
RESERVE_A = 1_000 * E
RESERVE_B = 2_000_000 * U


def amount_out(amount_in: int, reserve_in: int, reserve_out: int) -> int:
    """ConstantProductPair.getAmountOut: 0.3% fee, rounded down."""
    return amount_in * 997 * reserve_out // (reserve_in * 1000 + amount_in * 997)


def clear(xa: int, xb: int, a: int = RESERVE_A, b: int = RESERVE_B) -> tuple[str, int, int, int, int]:
    """Return (case, residualIn, residualOut, potA, potB) exactly as the contract computes them."""
    excess_a, need_a = 997 * b * xa, 1000 * a * xb
    excess_b, need_b = 997 * a * xb, 1000 * b * xa
    if excess_a > need_a:
        r = (excess_a - need_a) // (997 * (b + xb))
        out = amount_out(r, a, b) if r else 0
        if out:
            return "A excess", r, out, xa - r, xb + out
    elif excess_b > need_b:
        r = (excess_b - need_b) // (997 * (a + xa))
        out = amount_out(r, b, a) if r else 0
        if out:
            return "B excess", r, out, xa + out, xb - r
    return "fee band", 0, 0, xa, xb


def main() -> None:
    cases = [
        (10 * E, 30_000 * U),
        (30 * E, 10_000 * U),
        (10 * E, 20_000 * U),
        (10 * E, 20_050 * U),
        (0, 100_000 * U),
        (60 * E, 0),
    ]
    for xa, xb in cases:
        case, r, out, pot_a, pot_b = clear(xa, xb)
        print(f"XA={xa} XB={xb}: {case}, residualIn={r}, residualOut={out}, potA={pot_a}, potB={pot_b}")
        if xa:
            print(f"    A-seller price = {pot_b * E // xa} USDC base units per ETH")
        if xb and pot_a:
            print(f"    B-seller price = {xb * E // pot_a} USDC base units per ETH")

    _, _, _, pot_a, pot_b = clear(10 * E, 30_000 * U)
    print(f"3-order split of case 1: alice 4 ETH -> {4 * E * pot_b // (10 * E)}, "
          f"carol 6 ETH -> {6 * E * pot_b // (10 * E)}, bob -> {30_000 * U * pot_a // (30_000 * U)}")
    direct = amount_out(60 * E, RESERVE_A, RESERVE_B)
    print(f"one-sided 20 + 40 ETH: total {direct}, 20 ETH share {20 * E * direct // (60 * E)}, "
          f"40 ETH share {40 * E * direct // (60 * E)}")
    print(f"direct swap of 1 ETH: {amount_out(E, RESERVE_A, RESERVE_B)}")


if __name__ == "__main__":
    main()
