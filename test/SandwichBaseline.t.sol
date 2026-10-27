// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";
import {NaiveRouter} from "../src/NaiveRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {SandwichAttacker} from "./harness/SandwichAttacker.sol";

/// @notice Phase 2 baseline: a victim swapping through NaiveRouter gets sandwiched. Reproduces the LEARN.md 0.2.5
///         tables with exact integer math. Run `forge test --mc SandwichBaselineTest -vv` to print the tables.
contract SandwichBaselineTest is Test {
    uint256 internal constant BPS = 10_000;
    /// @dev The pair's reserve cap, so it never binds in either token's units (a flash loan in practice).
    uint256 internal constant UNLIMITED_BUDGET = type(uint112).max;
    /// @dev Phase 0 values are float64 rounded to 0.01 USDC; integer math may differ by a few cents.
    uint256 internal constant PHASE0_TOLERANCE_USDC = 0.05e6;

    uint256 internal constant DEFAULT_POOL_ETH = 1_000e18;
    uint256 internal constant DEFAULT_POOL_USDC = 2_000_000e6;
    uint256 internal constant DEFAULT_SLIPPAGE_BPS = 100;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    ConstantProductPair internal pair;
    NaiveRouter internal router;
    SandwichAttacker internal attacker;

    address internal lp = makeAddr("lp");
    address internal victim = makeAddr("victim");

    /// @dev Everything measured in one sandwich. Profit and loss are in `tokenIn` units.
    struct Result {
        uint256 fairOut; // victim output with no attack
        uint256 minOut; // victim's limit
        uint256 frontRun; // attacker leg 1 input
        uint256 attackerBought; // attacker leg 1 output
        uint256 victimOut; // what the victim actually received
        int256 profit; // attacker: back-run output minus front-run input
        uint256 victimLoss; // (fairOut - victimOut) valued at the victim's no-attack average price
        bool maximal; // one more wei of front-run would have made the victim revert
    }

    function setUp() public {
        _deployPool(DEFAULT_POOL_ETH, DEFAULT_POOL_USDC);
    }

    // ---------- the headline scenario (LEARN 0.2.5 worked example) ----------

    function test_sandwich_100kVictim_matchesPhase0() public {
        Result memory r = _sandwichPct(address(usdc), 100_000e6, DEFAULT_SLIPPAGE_BPS);

        assertGe(r.victimOut, r.minOut, "victim must not revert");
        assertTrue(r.maximal, "attacker pushes victim exactly to minOut");
        assertApproxEqAbs(r.fairOut, 47.483e18, 0.0001e18);
        assertApproxEqAbs(r.minOut, 47.0081e18, 0.0001e18);
        assertApproxEqAbs(r.frontRun, 10_336.55e6, PHASE0_TOLERANCE_USDC);
        assertApproxEqAbs(r.attackerBought, 5.1264e18, 0.0001e18);
        assertApproxEqAbs(r.profit, int256(981.55e6), PHASE0_TOLERANCE_USDC);
        assertApproxEqAbs(r.victimLoss, 1_000e6, PHASE0_TOLERANCE_USDC);
    }

    function test_sandwich_smallVictimIsUnprofitable() public {
        Result memory r = _sandwichPct(address(usdc), 1_000e6, DEFAULT_SLIPPAGE_BPS);
        assertLt(r.profit, 0);
        assertApproxEqAbs(r.profit, -int256(50.22e6), PHASE0_TOLERANCE_USDC);
    }

    function test_sandwich_deepPoolIsUnprofitable() public {
        _deployPool(20_000e18, 40_000_000e6);
        Result memory r = _sandwichPct(address(usdc), 100_000e6, DEFAULT_SLIPPAGE_BPS);
        assertLt(r.profit, 0);
        assertApproxEqAbs(r.profit, -int256(208.03e6), PHASE0_TOLERANCE_USDC);
    }

    /// The harness is direction-agnostic: a victim selling ETH is sandwiched the same way, with profit in ETH.
    function test_sandwich_victimSellingEth() public {
        Result memory r = _sandwichPct(address(weth), 50e18, DEFAULT_SLIPPAGE_BPS);
        assertGe(r.victimOut, r.minOut);
        assertTrue(r.maximal);
        assertGt(r.profit, 0);
        assertApproxEqRel(r.victimLoss, 0.5e18, 0.01e18); // about 1% of 50 ETH
    }

    /// Without a victim between the legs, the same round trip only pays fees: the profit comes from the victim.
    function test_roundTripWithoutVictim_loses() public {
        uint256 frontRun = 10_336.55e6;
        usdc.mint(address(attacker), frontRun);
        attacker.frontRun(address(usdc), frontRun);
        uint256 back = attacker.backRun();
        assertLt(back, frontRun);
    }

    // ---------- break it on purpose: minOut = 0 ----------

    /// With no slippage limit, only the attacker's capital bounds the loss (the March 2025 USDC/USDT victim).
    function test_sandwich_zeroMinOut_lossBoundedOnlyByAttackerBudget() public {
        uint256 victimIn = 100_000e6;
        uint256 budget = 2_000_000e6; // as much USDC as the whole pool holds
        Result memory r = _sandwich(address(usdc), victimIn, 0, budget);

        assertEq(r.frontRun, budget, "no limit binds, so the attacker spends the full budget");
        assertGt(r.victimLoss, victimIn / 2, "victim loses more than half");
        assertGt(r.profit, SafeCast.toInt256(victimIn / 2), "attacker takes more than half the trade");
        console2.log("minOut = 0, attacker budget 2,000,000 USDC, victim 100,000 USDC:");
        console2.log("  victim ETH out (fair -> got):", _fmt(r.fairOut, 18, 4), "->", _fmt(r.victimOut, 18, 4));
        console2.log("  victim loss USDC:", _fmt(r.victimLoss, 6, 2));
        console2.log("  attacker profit USDC:", _fmtSigned(r.profit, 6, 2));
    }

    // ---------- fuzz ----------

    /// Sandwiched victims land in [minOut, fairOut], and the attacker always reaches the minOut boundary.
    function testFuzz_sandwich_victimBetweenMinOutAndFair(uint256 victimIn, uint256 slippageBps) public {
        victimIn = bound(victimIn, 1_000e6, 1_000_000e6);
        slippageBps = bound(slippageBps, 1, 500);
        Result memory r = _sandwichPct(address(usdc), victimIn, slippageBps);

        assertGe(r.victimOut, r.minOut);
        assertLe(r.victimOut, r.fairOut);
        assertLe(r.fairOut - r.victimOut, r.fairOut - r.minOut, "loss is capped by the slippage tolerance");
        assertTrue(r.maximal);
    }

    /// In a 20,000 ETH pool, no front-run size in (0, max] makes a 100k / 1% sandwich profitable.
    function testFuzz_deepPool_noProfitableFrontRunSize(uint256 frontRun) public {
        _deployPool(20_000e18, 40_000_000e6);
        uint256 victimIn = 100_000e6;
        uint256 minOut = _minOut(pair.quote(address(usdc), victimIn), DEFAULT_SLIPPAGE_BPS);
        uint256 maxFrontRun = attacker.optimalFrontRun(address(usdc), victimIn, minOut, UNLIMITED_BUDGET);
        frontRun = bound(frontRun, 1, maxFrontRun);
        assertLt(attacker.expectedProfit(address(usdc), frontRun, victimIn), 0);
    }

    // ---------- tables (LEARN 0.2.5, re-derived in integer math) ----------

    function test_table_lossVsTradeSize() public {
        uint256[6] memory sizes = [uint256(1_000e6), 10_000e6, 50_000e6, 100_000e6, 250_000e6, 500_000e6];
        int256[6] memory phase0Profit = [int256(-50.22e6), 39.59e6, 448.41e6, 981.55e6, 2_728.18e6, 6_128.92e6];

        console2.log("Pool 1,000 ETH / 2,000,000 USDC, slippage 1%");
        console2.log(
            "| Victim USDC | ETH out (no attack) | ETH out (sandwiched) | Victim loss USDC | Loss % | Front-run USDC | Attacker profit USDC |"
        );
        for (uint256 i = 0; i < sizes.length; i++) {
            _deployPool(DEFAULT_POOL_ETH, DEFAULT_POOL_USDC);
            Result memory r = _sandwichPct(address(usdc), sizes[i], DEFAULT_SLIPPAGE_BPS);
            console2.log(
                string.concat(
                    "| ",
                    _fmt(sizes[i], 6, 0),
                    " | ",
                    _fmt(r.fairOut, 18, 4),
                    " | ",
                    _fmt(r.victimOut, 18, 4),
                    " | ",
                    _fmt(r.victimLoss, 6, 2),
                    " | ",
                    _fmt(Math.mulDiv(r.victimLoss, 100 * 1e6, sizes[i]), 6, 2),
                    "% | ",
                    _fmt(r.frontRun, 6, 2),
                    " | ",
                    _fmtSigned(r.profit, 6, 2),
                    " |"
                )
            );
            assertApproxEqAbs(r.profit, phase0Profit[i], PHASE0_TOLERANCE_USDC);
            assertApproxEqRel(r.victimLoss, sizes[i] / 100, 0.001e18);
        }
    }

    function test_table_lossVsPoolDepth() public {
        uint256[5] memory poolEth = [uint256(250e18), 500e18, 1_000e18, 5_000e18, 20_000e18];
        int256[5] memory phase0Profit = [int256(1_173.82e6), 1_060.72e6, 981.55e6, 701.62e6, -208.03e6];

        console2.log("Victim 100,000 USDC, slippage 1%, spot 2,000 USDC/ETH");
        console2.log("| Pool ETH | Pool USDC | Victim loss USDC | Front-run USDC | Attacker profit USDC |");
        for (uint256 i = 0; i < poolEth.length; i++) {
            uint256 poolUsdc = poolEth[i] * 2_000 / 1e12; // 18 -> 6 decimals at spot 2,000
            _deployPool(poolEth[i], poolUsdc);
            Result memory r = _sandwichPct(address(usdc), 100_000e6, DEFAULT_SLIPPAGE_BPS);
            console2.log(
                string.concat(
                    "| ",
                    _fmt(poolEth[i], 18, 0),
                    " | ",
                    _fmt(poolUsdc, 6, 0),
                    " | ",
                    _fmt(r.victimLoss, 6, 2),
                    " | ",
                    _fmt(r.frontRun, 6, 2),
                    " | ",
                    _fmtSigned(r.profit, 6, 2),
                    " |"
                )
            );
            assertApproxEqAbs(r.profit, phase0Profit[i], PHASE0_TOLERANCE_USDC);
        }
    }

    function test_table_lossVsSlippage() public {
        uint256[5] memory slippageBps = [uint256(10), 50, 100, 300, 500];
        int256[5] memory phase0Profit = [int256(98.21e6), 490.93e6, 981.55e6, 2_940.86e6, 4_895.12e6];

        console2.log("Victim 100,000 USDC, pool 1,000 ETH / 2,000,000 USDC");
        console2.log("| Slippage | Victim loss USDC | Front-run USDC | Attacker profit USDC |");
        for (uint256 i = 0; i < slippageBps.length; i++) {
            _deployPool(DEFAULT_POOL_ETH, DEFAULT_POOL_USDC);
            Result memory r = _sandwichPct(address(usdc), 100_000e6, slippageBps[i]);
            console2.log(
                string.concat(
                    "| ",
                    _fmt(slippageBps[i], 2, 1),
                    "% | ",
                    _fmt(r.victimLoss, 6, 2),
                    " | ",
                    _fmt(r.frontRun, 6, 2),
                    " | ",
                    _fmtSigned(r.profit, 6, 2),
                    " |"
                )
            );
            assertApproxEqAbs(r.profit, phase0Profit[i], PHASE0_TOLERANCE_USDC);
        }
    }

    // ---------- helpers ----------

    /// @dev Fresh tokens, pool, router and attacker, so every table row starts from the same clean state.
    function _deployPool(uint256 poolEth, uint256 poolUsdc) internal {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pair = new ConstantProductPair(IERC20(address(weth)), IERC20(address(usdc)));
        router = new NaiveRouter(pair);
        attacker = new SandwichAttacker(pair);

        weth.mint(lp, poolEth);
        usdc.mint(lp, poolUsdc);
        vm.startPrank(lp);
        weth.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        pair.addLiquidity(poolEth, poolUsdc);
        vm.stopPrank();

        vm.startPrank(victim);
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _minOut(uint256 fairOut, uint256 slippageBps) internal pure returns (uint256) {
        return fairOut * (BPS - slippageBps) / BPS;
    }

    function _sandwichPct(address tokenIn, uint256 victimIn, uint256 slippageBps) internal returns (Result memory) {
        uint256 minOut = _minOut(pair.quote(tokenIn, victimIn), slippageBps);
        return _sandwich(tokenIn, victimIn, minOut, UNLIMITED_BUDGET);
    }

    /// @dev Executes the bundle [attacker front-run, victim swap via NaiveRouter, attacker back-run] and measures it.
    function _sandwich(address tokenIn, uint256 victimIn, uint256 minOut, uint256 budget)
        internal
        returns (Result memory r)
    {
        r.fairOut = pair.quote(tokenIn, victimIn);
        r.minOut = minOut;
        r.frontRun = attacker.optimalFrontRun(tokenIn, victimIn, minOut, budget);
        r.maximal = r.frontRun == budget || attacker.victimOutAfter(tokenIn, r.frontRun + 1, victimIn) < minOut;
        int256 predicted = attacker.expectedProfit(tokenIn, r.frontRun, victimIn);

        if (r.frontRun > 0) {
            MockERC20(tokenIn).mint(address(attacker), r.frontRun);
            r.attackerBought = attacker.frontRun(tokenIn, r.frontRun);
        }

        MockERC20(tokenIn).mint(victim, victimIn);
        vm.prank(victim);
        r.victimOut = router.swapExactIn(tokenIn, victimIn, minOut, victim, block.timestamp);

        if (r.frontRun > 0) {
            uint256 back = attacker.backRun();
            r.profit = SafeCast.toInt256(back) - SafeCast.toInt256(r.frontRun);
            assertEq(r.profit, predicted, "simulation must match execution to the wei");
        }
        r.victimLoss = Math.mulDiv(r.fairOut - r.victimOut, victimIn, r.fairOut);
    }

    /// @dev Fixed-point to string, truncated to `shown` decimals (display only).
    function _fmt(uint256 value, uint256 decimals, uint256 shown) internal pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        string memory whole = vm.toString(value / unit);
        if (shown == 0) return whole;
        string memory frac = vm.toString((value % unit) / 10 ** (decimals - shown));
        while (bytes(frac).length < shown) {
            frac = string.concat("0", frac);
        }
        return string.concat(whole, ".", frac);
    }

    function _fmtSigned(int256 value, uint256 decimals, uint256 shown) internal pure returns (string memory) {
        string memory magnitude = _fmt(SignedMath.abs(value), decimals, shown);
        return value < 0 ? string.concat("-", magnitude) : magnitude;
    }
}
