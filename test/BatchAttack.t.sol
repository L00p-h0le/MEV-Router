// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {BatchRouter} from "../src/BatchRouter.sol";
import {SandwichAttacker} from "./harness/SandwichAttacker.sol";
import {BatchRouterFixture} from "./utils/BatchRouterFixture.sol";

/// @notice Phase 5: the Phase 2 attacker against BatchRouter (THREAT_MODEL T1, T2, T4, T6, T8).
/// @dev Same pool, victim and 1% slippage as the Phase 2 baseline, so the rows compare directly. Attacker model as
///      D-011 plus D-020: unlimited capital, it can be the settler, and it sees every revealed `minOut`.
///      Run `forge test --mc BatchAttackTest -vv` to print the before/after tables.
contract BatchAttackTest is BatchRouterFixture {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SLIPPAGE_BPS = 100;
    uint256 internal constant VICTIM_IN = 100_000 * U;
    /// @dev Upper bound for every front-run search: the pool's whole USDC reserve.
    uint256 internal constant SEARCH_CAP = RESERVE_B;

    SandwichAttacker internal attacker;
    address internal victim = makeAddr("victim");
    address internal mev = makeAddr("mev");

    /// @dev One measured attack. Amounts are in USDC base units unless named otherwise.
    struct Outcome {
        uint256 fairOut; // victim ETH with no attack (same batch, same reserves)
        uint256 victimOut; // victim ETH actually received
        uint256 attackSize; // attacker USDC put at risk (front-run or joined order)
        int256 profit; // attacker USDC back minus USDC in
        uint256 victimLoss; // D-012: (fairOut - victimOut) valued at the victim's no-attack price
    }

    function setUp() public override {
        super.setUp();
        attacker = new SandwichAttacker(pair);
    }

    // --------------------------------------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------------------------------------

    function _minOut(uint256 fairOut) internal pure returns (uint256) {
        return fairOut * (BPS - SLIPPAGE_BPS) / BPS;
    }

    function _victimSpec(uint256 victimIn) internal view returns (Spec memory) {
        return _order(victim, false, victimIn, _minOut(pair.quote(address(usdc), victimIn)));
    }

    function _loss(uint256 fairOut, uint256 got, uint256 victimIn) internal pure returns (uint256) {
        return Math.mulDiv(fairOut - got, victimIn, fairOut);
    }

    /// @dev Victim payout in a one-sided USDC batch of `victimIn + joined` (SPEC §7: r = XB, pot = out(XB)).
    function _oneSidedShare(uint256 victimIn, uint256 joined) internal view returns (uint256 victimOut, uint256 pot) {
        pot = pair.getAmountOut(victimIn + joined, RESERVE_B, RESERVE_A);
        victimOut = Math.mulDiv(victimIn, pot, victimIn + joined);
    }

    /// @dev T8 sizing: the largest same-side order that still leaves the victim at its `minOut`.
    function _largestJoin(uint256 victimIn, uint256 minOut) internal view returns (uint256 lo) {
        uint256 hi = SEARCH_CAP;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            (uint256 out,) = _oneSidedShare(victimIn, mid);
            if (out >= minOut) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @dev T8 prediction: the attacker's share of the batch, sold straight back into the post-settle pool.
    function _predictJoin(uint256 victimIn, uint256 joined) internal view returns (int256 profit, uint256 victimOut) {
        uint256 pot;
        (victimOut, pot) = _oneSidedShare(victimIn, joined);
        uint256 share = Math.mulDiv(joined, pot, victimIn + joined);
        uint256 back = pair.getAmountOut(share, RESERVE_A - pot, RESERVE_B + victimIn + joined);
        profit = SafeCast.toInt256(back) - SafeCast.toInt256(joined);
    }

    /// @dev True if, after an AMM front-run of `frontRun` USDC, settling now would still fill the victim.
    function _victimSurvives(uint256 batchId, uint256 victimIdx, uint256 frontRun) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        if (frontRun > 0) {
            usdc.mint(address(attacker), frontRun);
            attacker.frontRun(address(usdc), frontRun);
        }
        ok = router.previewOut(batchId, victimIdx) > 0;
        vm.revertToState(snap);
    }

    /// @dev T2: the attacker bundles [AMM front-run, settle, AMM back-run] itself, sized to the largest front-run
    ///      that keeps the victim filled. Searched with previewOut, so it works for any batch composition.
    function _settleSandwich(uint256 batchId, uint256 victimIdx) internal returns (Outcome memory o) {
        o.fairOut = router.previewOut(batchId, victimIdx);
        uint256 lo;
        uint256 hi = SEARCH_CAP;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (_victimSurvives(batchId, victimIdx, mid)) lo = mid;
            else hi = mid - 1;
        }
        o.attackSize = lo;

        if (lo > 0) {
            usdc.mint(address(attacker), lo);
            attacker.frontRun(address(usdc), lo);
        }
        router.settle(batchId);
        if (lo > 0) o.profit = SafeCast.toInt256(attacker.backRun()) - SafeCast.toInt256(lo);

        o.victimOut = router.previewOut(batchId, victimIdx);
        o.victimLoss = _loss(o.fairOut, o.victimOut, router.getOrder(batchId, victimIdx).amountIn);
    }

    /// @dev Sell `amount` WETH held by `who` straight into the pair; returns the USDC received.
    function _sellEth(address who, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        weth.approve(address(pair), amount);
        uint256 back = pair.swapExactIn(address(weth), amount, 0, who);
        vm.stopPrank();
        return back;
    }

    // --------------------------------------------------------------------------------------------------------
    // T1: the sandwich legs placed inside the batch
    // --------------------------------------------------------------------------------------------------------

    /// @dev The Phase 2 bundle, translated: a buy order before the victim and a sell order after it, sized like the
    ///      naive attack. Inside one batch both legs clear at the same P, so each leg receives at most its input
    ///      valued at P (exact, cross-multiplied). Valuing the combined position at the floored display price can
    ///      show +1 base unit; that is the display rounding, not a gain, so the exact per-leg checks are asserted.
    function test_T1_inBatchSandwich_neverProfitsAtTheClearingPrice() public {
        Spec memory v = _victimSpec(VICTIM_IN);
        uint256 frontRun = attacker.optimalFrontRun(address(usdc), VICTIM_IN, v.minOut, type(uint112).max);
        uint256 backRunEth = pair.quote(address(usdc), frontRun);
        Spec[] memory specs = _three(_order(mev, false, frontRun, 0), v, _order(mev, true, backRunEth, 0));

        (uint256 b, uint256[] memory idx) = _run(specs);
        for (uint256 k; k < 3; ++k) {
            _claim(b, idx[k]);
        }
        BatchRouter.Batch memory batch = router.getBatch(b);
        // Both legs escrowed exactly their amountIn, so every WETH the attacker holds came from the buy leg and every
        // USDC from the sell leg.
        assertLe(weth.balanceOf(mev) * batch.filledInB, frontRun * batch.potA, "buy leg got more than P");
        assertLe(usdc.balanceOf(mev) * batch.filledInA, backRunEth * batch.potB, "sell leg got more than P");

        (uint256 priceA,) = _prices(b);
        int256 usdcNet = SafeCast.toInt256(usdc.balanceOf(mev)) - SafeCast.toInt256(frontRun);
        int256 ethNet = SafeCast.toInt256(weth.balanceOf(mev)) - SafeCast.toInt256(backRunEth);
        console2.log(
            "T1 in-batch legs: attacker P&L at the displayed P (USDC base units):",
            usdcNet + ethNet * SafeCast.toInt256(priceA) / SafeCast.toInt256(E)
        );
        uint256 directOut = pair.getAmountOut(VICTIM_IN, RESERVE_B, RESERVE_A);
        console2.log("T1 victim ETH, batch vs direct swap (wei):", weth.balanceOf(victim), directOut);
        assertGe(weth.balanceOf(victim), directOut, "the attacker's opposing leg only adds netting for the victim");
    }

    /// @dev Moving the attacker's legs around the victim changes nothing for anyone.
    function test_T1_positionOfAttackerLegsIsIrrelevant() public {
        Spec memory v = _victimSpec(VICTIM_IN);
        Spec memory buy = _order(mev, false, 10_000 * U, 0);
        Spec memory sell = _order(carol, true, 5 * E, 0);
        Spec[3][3] memory orders = [[buy, v, sell], [v, buy, sell], [sell, buy, v]];
        // Role of each position in each ordering: 0 = buy, 1 = victim, 2 = sell.
        uint8[3][3] memory roles = [[0, 1, 2], [1, 0, 2], [2, 0, 1]];

        uint256[3] memory expected;
        for (uint256 o; o < 3; ++o) {
            uint256 snap = vm.snapshotState();
            Spec[] memory specs = _three(orders[o][0], orders[o][1], orders[o][2]);
            (uint256 b, uint256[] memory idx) = _run(specs);
            for (uint256 k; k < 3; ++k) {
                uint256 out = router.previewOut(b, idx[k]);
                if (o == 0) expected[roles[o][k]] = out;
                else assertEq(out, expected[roles[o][k]], "payout depends on position");
            }
            vm.revertToState(snap);
        }
    }

    /// @dev Any pair of attacker legs, any victim size: at the clearing price the legs never gain, and the victim is
    ///      never filled below its limit.
    function testFuzz_T1_attackerLegsNeverGainAtClearingPrice(uint256 victimIn, uint256 buyIn, uint256 sellIn) public {
        victimIn = bound(victimIn, 1_000 * U, 500_000 * U);
        buyIn = bound(buyIn, 10 * U, 200_000 * U);
        sellIn = bound(sellIn, E / 100, 100 * E);
        Spec memory v = _victimSpec(victimIn);
        (uint256 b, uint256[] memory idx) = _run(_three(_order(mev, false, buyIn, 0), v, _order(mev, true, sellIn, 0)));
        BatchRouter.Batch memory batch = router.getBatch(b);

        if (_status(b, idx[0]) == BatchRouter.Status.Filled) {
            assertLe(router.previewOut(b, idx[0]) * batch.filledInB, buyIn * batch.potA, "buy leg beats P");
        }
        if (_status(b, idx[2]) == BatchRouter.Status.Filled) {
            assertLe(router.previewOut(b, idx[2]) * batch.filledInA, sellIn * batch.potB, "sell leg beats P");
        }
        if (_status(b, idx[1]) == BatchRouter.Status.Filled) assertGe(router.previewOut(b, idx[1]), v.minOut);
    }

    // --------------------------------------------------------------------------------------------------------
    // T2: sandwiching the settle call
    // --------------------------------------------------------------------------------------------------------

    /// @dev A batch holding only the victim swaps exactly the victim's input, and the victim's minOut is public
    ///      after reveal. The attacker settles itself between its two AMM legs: the naive sandwich, to the wei.
    function test_T2_settleSandwich_oneSidedBatchEqualsNaiveSandwich() public {
        Spec memory v = _victimSpec(VICTIM_IN);
        uint256 naiveFrontRun = attacker.optimalFrontRun(address(usdc), VICTIM_IN, v.minOut, type(uint112).max);
        int256 naiveProfit = attacker.expectedProfit(address(usdc), naiveFrontRun, VICTIM_IN);

        (uint256 b, uint256[] memory idx) = _prepare(_one(v));
        Outcome memory o = _settleSandwich(b, idx[0]);

        assertEq(o.attackSize, naiveFrontRun, "same front-run as against NaiveRouter");
        assertEq(o.profit, naiveProfit, "same profit as against NaiveRouter");
        assertApproxEqAbs(o.profit, int256(981.55e6), 0.05e6, "Phase 2 headline profit");
        assertGe(o.victimOut, v.minOut);
        assertApproxEqAbs(o.victimLoss, 1_000 * U, 0.05e6, "victim loses its whole 1% tolerance");
    }

    /// @dev Counter-intuitive, and the reason D-021 exists. Opposing flow gives the victim a better batch price than
    ///      the direct quote its minOut was set from. That extra slack above minOut is extractable too, so the victim
    ///      loses MORE against its batch-fair output, and the attacker earns more than naive. minOut is still never
    ///      breached. Part of the loss goes to the loose counterparty, who sells ETH at the pushed-up price.
    function test_T2_settleSandwich_counterflowSlackIsAlsoExtracted() public {
        uint256 snap = vm.snapshotState();
        (uint256 b, uint256[] memory idx) = _prepare(_one(_victimSpec(VICTIM_IN)));
        Outcome memory alone = _settleSandwich(b, idx[0]);
        vm.revertToState(snap);

        Spec memory v = _victimSpec(VICTIM_IN);
        (b, idx) = _prepare(_two(v, _order(carol, true, 10 * E, 0)));
        Outcome memory netted = _settleSandwich(b, idx[0]);

        assertGt(netted.fairOut, alone.fairOut, "netting improves the victim's batch-fair output");
        assertGe(netted.victimOut, v.minOut, "minOut still holds");
        assertGt(netted.victimLoss, alone.victimLoss, "the netting gain is extracted as well");
        assertGt(netted.profit, alone.profit);
    }

    // --------------------------------------------------------------------------------------------------------
    // T8 and T4: join the victim's side of the batch, back-run on the AMM after settle
    // --------------------------------------------------------------------------------------------------------

    /// @dev Direction and size leak at commit (T5); minOut leaks at reveal. An attacker that joins the victim's side
    ///      with the largest order the victim's limit allows, then sells its share into the moved pool, keeps
    ///      almost all of the naive profit. Expected integers: `script/attack_reference.py`.
    function test_T8_joinAndBackRun_keepsMostOfTheNaiveProfit() public {
        Spec memory v = _victimSpec(VICTIM_IN);
        uint256 joined = _largestJoin(VICTIM_IN, v.minOut);
        (int256 predicted, uint256 predictedVictimOut) = _predictJoin(VICTIM_IN, joined);
        assertEq(joined, 21_272_909_638);

        (uint256 b, uint256[] memory idx) = _run(_two(v, _order(mev, false, joined, 0)));
        _claim(b, idx[0]);
        _claim(b, idx[1]);
        uint256 back = _sellEth(mev, weth.balanceOf(mev));
        int256 profit = SafeCast.toInt256(back) - SafeCast.toInt256(joined);

        assertEq(profit, predicted, "prediction matches execution to the base unit");
        assertEq(profit, 920_099_217);
        assertEq(weth.balanceOf(victim), predictedVictimOut);
        assertGe(weth.balanceOf(victim), v.minOut);
        (uint256 oneMore,) = _oneSidedShare(VICTIM_IN, joined + 1);
        assertLt(oneMore, v.minOut, "the join is maximal");
        assertEq(
            _loss(pair.getAmountOut(VICTIM_IN, RESERVE_B, RESERVE_A), weth.balanceOf(victim), VICTIM_IN), 999_999_999
        );
    }

    /// @dev The attacker cannot see minOut at commit time, so it commits a ladder of orders and reveals only as many
    ///      as the victim's revealed limit allows (T4: the free option). The unrevealed rung costs one bond.
    function test_T4_ladderOfWithheldReveals_sizesTheJoinAfterSeeingMinOut() public {
        uint256 rung = 3_000 * U;
        uint256 rungs = 8;
        uint256 b = router.currentBatchId();
        Spec memory v = _victimSpec(VICTIM_IN);
        uint256 victimIdx = _commit(v);
        Spec[] memory ladder = new Spec[](rungs);
        uint256[] memory ladderIdx = new uint256[](rungs);
        for (uint256 k; k < rungs; ++k) {
            ladder[k] = _order(mev, false, rung, k); // distinct minOut (wei) only to give each rung its own salt
            ladderIdx[k] = _commit(ladder[k]);
        }

        (, uint256 revealStart, uint256 revealEnd) = router.batchWindows(b);
        vm.roll(revealStart);
        _reveal(b, victimIdx, v);
        uint256 publicMinOut = router.getOrder(b, victimIdx).minOut;
        uint256 revealCount = _largestJoin(VICTIM_IN, publicMinOut) / rung;
        assertEq(revealCount, 7);
        for (uint256 k; k < revealCount; ++k) {
            _reveal(b, ladderIdx[k], ladder[k]);
        }

        vm.roll(revealEnd);
        router.settle(b);
        _claim(b, victimIdx);
        for (uint256 k; k < rungs; ++k) {
            _claim(b, ladderIdx[k]);
        }
        uint256 joined = revealCount * rung;
        uint256 back = _sellEth(mev, weth.balanceOf(mev));
        (int256 predicted,) = _predictJoin(VICTIM_IN, joined);

        assertEq(SafeCast.toInt256(back) - SafeCast.toInt256(joined), predicted);
        assertEq(usdc.balanceOf(mev), back + rung, "the withheld rung's escrow came back");
        assertEq(router.forfeitedBonds(), BOND, "the option cost exactly one bond");
        assertGe(weth.balanceOf(victim), v.minOut);
        console2.log("T4 ladder: rungs revealed of 8:", revealCount);
        console2.log("T4 ladder: USDC profit before the 0.01 ETH bond:", predicted);
    }

    /// @dev If no victim shows up, the attacker withholds everything: it gets every escrow back and loses the bonds.
    function test_T4_noVictim_attackerWithholdsAndLosesOnlyBonds() public {
        Spec memory s = _order(mev, false, 20_000 * U, 0);
        s.reveal = false;
        (uint256 b, uint256[] memory idx) = _run(_one(s));
        _claim(b, idx[0]);
        assertEq(usdc.balanceOf(mev), 20_000 * U);
        assertEq(mev.balance, 0);
        assertEq(router.forfeitedBonds(), BOND);
    }

    // --------------------------------------------------------------------------------------------------------
    // T6: flooding the batch with tiny orders
    // --------------------------------------------------------------------------------------------------------

    /// @dev 100 orders of 1 wei of WETH fill the batch. The victim is pushed to the next batch (C blocks later). The
    ///      attacker reveals everything; 1 wei of WETH quotes 0 USDC, so every order is excluded (D-016) and refunded,
    ///      and the attack costs only gas. (1 base unit of USDC would NOT be excluded: it still buys ~5e8 wei of ETH.)
    function test_T6_flood_delaysVictimOneBatch_costsOnlyGas() public {
        uint256 n = router.MAX_ORDERS_PER_BATCH();
        uint256 b = router.currentBatchId();
        weth.mint(mev, n);
        vm.deal(mev, n * BOND);
        vm.prank(mev);
        weth.approve(address(router), n);

        uint256 commitGas;
        for (uint256 k; k < n; ++k) {
            bytes32 hash = router.computeCommitHash(address(weth), address(usdc), 1, 0, bytes32(k), mev);
            vm.prank(mev);
            uint256 g = gasleft();
            router.commit{value: BOND}(hash, address(weth), 1);
            commitGas += g - gasleft();
        }

        Spec memory v = _victimSpec(VICTIM_IN);
        usdc.mint(victim, VICTIM_IN);
        vm.deal(victim, BOND);
        vm.startPrank(victim);
        usdc.approve(address(router), VICTIM_IN);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.BatchFull.selector, b));
        router.commit{value: BOND}(bytes32(0), address(usdc), VICTIM_IN);
        vm.stopPrank();

        (uint256 nextCommitStart,,) = router.batchWindows(b + 1);
        vm.roll(nextCommitStart);
        assertEq(router.currentBatchId(), b + 1, "the victim's earliest batch is the next one");
        _commit(v);

        (, uint256 revealStart, uint256 revealEnd) = router.batchWindows(b);
        vm.roll(revealStart);
        uint256 revealGas;
        for (uint256 k; k < n; ++k) {
            uint256 g = gasleft();
            router.reveal(b, k, 1, 0, bytes32(k));
            revealGas += g - gasleft();
        }
        vm.roll(revealEnd);
        uint256 settleGas = gasleft();
        router.settle(b);
        settleGas -= gasleft();
        for (uint256 k; k < n; ++k) {
            assertEq(uint8(_status(b, k)), uint8(BatchRouter.Status.Excluded));
            _claim(b, k);
        }

        assertEq(weth.balanceOf(mev), n, "every wei refunded");
        assertEq(mev.balance, n * BOND, "every bond refunded");
        console2.log("T6 flood of 100 orders, gas: commits", commitGas, "reveals", revealGas);
        console2.log("T6 flood, settle gas (paid by whoever settles):", settleGas);
    }

    /// @dev Spam moves the price by its own size and no more. Ten 1-wei WETH orders are excluded (they quote 0); ten
    ///      1-unit USDC orders are real same-side flow, so the victim's batch is exactly a one-sided batch of V + 10.
    function test_T6_tinyOrdersMoveThePriceOnlyByTheirOwnSize() public {
        Spec[] memory specs = new Spec[](21);
        specs[0] = _victimSpec(VICTIM_IN);
        for (uint256 k = 1; k < specs.length; ++k) {
            specs[k] = _order(mev, k % 2 == 0, 1, k);
        }
        (uint256 b, uint256[] memory idx) = _run(specs);
        for (uint256 k = 2; k < specs.length; k += 2) {
            assertEq(uint8(_status(b, idx[k])), uint8(BatchRouter.Status.Excluded));
        }
        (uint256 expected,) = _oneSidedShare(VICTIM_IN, 10);
        assertEq(router.previewOut(b, idx[0]), expected);
    }

    // --------------------------------------------------------------------------------------------------------
    // Before/after tables (printed with -vv)
    // --------------------------------------------------------------------------------------------------------

    function test_table_beforeAfter_vsTradeSize() public {
        uint256[6] memory sizes = [uint256(1_000 * U), 10_000 * U, 50_000 * U, 100_000 * U, 250_000 * U, 500_000 * U];
        console2.log("Pool 1,000 ETH / 2,000,000 USDC, victim buys ETH, slippage 1%. USDC.");
        console2.log(
            "| Victim | Naive: loss / attacker | Batch T1 in-batch legs | Batch T2 settle sandwich: loss / attacker | Batch T8 join + back-run: loss / attacker |"
        );
        for (uint256 i; i < sizes.length; ++i) {
            Outcome memory naive = _naiveOutcome(sizes[i]);
            Outcome memory t2 = _oneSidedSettleSandwich(sizes[i]);
            Outcome memory t8 = _joinOutcome(sizes[i]);
            assertEq(t2.profit, naive.profit, "T2 on a one-sided batch = naive");
            console2.log(
                string.concat(
                    "| ",
                    _fmt(sizes[i], 6, 0),
                    " | ",
                    _cells(naive),
                    " | 0 / <= 0 | ",
                    _cells(t2),
                    " | ",
                    _cells(t8),
                    " |"
                )
            );
        }
    }

    /// @dev The Phase 2 numbers, re-derived from the harness simulation (exact, see SandwichBaseline).
    function _naiveOutcome(uint256 victimIn) internal view returns (Outcome memory o) {
        o.fairOut = pair.quote(address(usdc), victimIn);
        o.attackSize = attacker.optimalFrontRun(address(usdc), victimIn, _minOut(o.fairOut), type(uint112).max);
        o.profit = attacker.expectedProfit(address(usdc), o.attackSize, victimIn);
        o.victimOut = attacker.victimOutAfter(address(usdc), o.attackSize, victimIn);
        o.victimLoss = _loss(o.fairOut, o.victimOut, victimIn);
    }

    function _oneSidedSettleSandwich(uint256 victimIn) internal returns (Outcome memory o) {
        uint256 snap = vm.snapshotState();
        (uint256 b, uint256[] memory idx) = _prepare(_one(_victimSpec(victimIn)));
        o = _settleSandwich(b, idx[0]);
        vm.revertToState(snap);
    }

    function _joinOutcome(uint256 victimIn) internal view returns (Outcome memory o) {
        o.fairOut = pair.quote(address(usdc), victimIn);
        o.attackSize = _largestJoin(victimIn, _minOut(o.fairOut));
        (o.profit, o.victimOut) = _predictJoin(victimIn, o.attackSize);
        o.victimLoss = _loss(o.fairOut, o.victimOut, victimIn);
    }

    function _cells(Outcome memory o) internal pure returns (string memory) {
        return string.concat(_fmt(o.victimLoss, 6, 2), " / ", _fmtSigned(o.profit, 6, 2));
    }

    function test_table_settleSandwich_vsCounterflow() public {
        uint256[5] memory counterEth = [uint256(0), 10 * E, 25 * E, 40 * E, 50 * E];
        console2.log("T2 settle sandwich, victim 100,000 USDC at 1%, plus an honest ETH seller (minOut 0). USDC.");
        console2.log(
            "| Counterflow ETH | Victim loss vs honest batch | Victim loss vs direct quote | Attacker front-run | Attacker profit |"
        );
        uint256 direct = pair.quote(address(usdc), VICTIM_IN);
        for (uint256 i; i < counterEth.length; ++i) {
            uint256 snap = vm.snapshotState();
            Spec[] memory specs = counterEth[i] == 0
                ? _one(_victimSpec(VICTIM_IN))
                : _two(_victimSpec(VICTIM_IN), _order(carol, true, counterEth[i], 0));
            (uint256 b, uint256[] memory idx) = _prepare(specs);
            Outcome memory o = _settleSandwich(b, idx[0]);
            vm.revertToState(snap);
            assertGe(o.victimOut, _minOut(direct), "never below minOut");
            console2.log(
                string.concat(
                    "| ",
                    _fmt(counterEth[i], 18, 0),
                    " | ",
                    _fmt(o.victimLoss, 6, 2),
                    " | ",
                    _fmt(_loss(direct, o.victimOut, VICTIM_IN), 6, 2),
                    " | ",
                    _fmt(o.attackSize, 6, 2),
                    " | ",
                    _fmtSigned(o.profit, 6, 2),
                    " |"
                )
            );
        }
    }

    // --------------------------------------------------------------------------------------------------------
    // Formatting (display only, truncated)
    // --------------------------------------------------------------------------------------------------------

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
