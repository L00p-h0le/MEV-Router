// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";
import {BatchRouter} from "../src/BatchRouter.sol";
import {BatchRouterFixture} from "./utils/BatchRouterFixture.sol";

/// @notice Phase 4 tests: netting, residual swap, uniform price, minOut exclusion, claims (SPEC.md §6-7).
/// @dev Expected integers come from `script/clearing_reference.py`, an exact mirror of the SPEC §7 formulas.
///      Pool, parameters and helpers: `BatchRouterFixture`.
contract BatchRouterSettlementTest is BatchRouterFixture {
    // --------------------------------------------------------------------------------------------------------
    // SPEC §7 reference table
    // --------------------------------------------------------------------------------------------------------

    function test_spec_bExcess_10ethVs30kUsdc() public {
        Spec[] memory specs = _two(_order(alice, true, 10 * E, 0), _order(bob, false, 30_000 * U, 0));
        (uint256 b,) = _prepare(specs);

        vm.expectEmit(address(router));
        emit BatchRouter.Settled(
            b,
            10 * E,
            30_000 * U,
            address(usdc),
            9_841_405_404,
            4_881_989_841_750_378_672,
            14_881_989_841_750_378_672,
            20_158_594_596
        );
        router.settle(b);

        (uint256 pA, uint256 pB) = _prices(b);
        assertEq(pA, 2_015_859_459);
        assertEq(pB, 2_015_859_459);
        (uint256 rA, uint256 rB) = pair.getReserves();
        assertEq(rA, RESERVE_A - 4_881_989_841_750_378_672);
        assertEq(rB, RESERVE_B + 9_841_405_404);
    }

    function test_spec_aExcess_30ethVs10kUsdc() public {
        Spec[] memory specs = _two(_order(alice, true, 30 * E, 0), _order(bob, false, 10_000 * U, 0));
        (uint256 b,) = _prepare(specs);

        vm.expectEmit(address(router));
        emit BatchRouter.Settled(
            b,
            30 * E,
            10_000 * U,
            address(weth),
            24_860_651_606_560_976_461,
            48_373_158_819,
            5_139_348_393_439_023_539,
            58_373_158_819
        );
        router.settle(b);

        (uint256 pA, uint256 pB) = _prices(b);
        assertEq(pA, 1_945_771_960);
        assertEq(pB, 1_945_771_960);
    }

    function test_spec_feeBand_atSpot_noAmmSwap() public {
        Spec[] memory specs = _two(_order(alice, true, 10 * E, 0), _order(bob, false, 20_000 * U, 0));
        (uint256 b, uint256[] memory idx) = _prepare(specs);

        vm.expectEmit(address(router));
        emit BatchRouter.Settled(b, 10 * E, 20_000 * U, address(0), 0, 0, 10 * E, 20_000 * U);
        router.settle(b);

        (uint256 rA, uint256 rB) = pair.getReserves();
        assertEq(rA, RESERVE_A, "pool untouched");
        assertEq(rB, RESERVE_B, "pool untouched");
        _claim(b, idx[0]);
        _claim(b, idx[1]);
        assertEq(usdc.balanceOf(alice), 20_000 * U, "perfect coincidence of wants");
        assertEq(weth.balanceOf(bob), 10 * E);
    }

    function test_spec_feeBand_offSpot_clearsAtRatio() public {
        Spec[] memory specs = _two(_order(alice, true, 10 * E, 0), _order(bob, false, 20_050 * U, 0));
        (uint256 b,) = _run(specs);
        (uint256 pA, uint256 pB) = _prices(b);
        assertEq(pA, 2_005_000_000);
        assertEq(pB, 2_005_000_000);
        assertEq(router.getBatch(b).potB, 20_050 * U);
    }

    function test_spec_oneSided_equalsDirectSwap() public {
        uint256 direct = pair.quote(address(usdc), 100_000 * U);
        assertEq(direct, 47_482_973_758_155_927_037);

        (uint256 b, uint256[] memory idx) = _run(_one(_order(bob, false, 100_000 * U, 0)));
        assertEq(router.getBatch(b).potA, direct);
        _claim(b, idx[0]);
        assertEq(weth.balanceOf(bob), direct, "batch of one = direct swap, to the wei");
        assertEq(weth.balanceOf(address(router)), 0);
    }

    // --------------------------------------------------------------------------------------------------------
    // Hand-computed batches (instruction.md Phase 4)
    // --------------------------------------------------------------------------------------------------------

    function test_handComputed_threeOrders_proRataSameSide() public {
        Spec[] memory specs =
            _three(_order(alice, true, 4 * E, 0), _order(carol, true, 6 * E, 0), _order(bob, false, 30_000 * U, 0));
        (uint256 b, uint256[] memory idx) = _run(specs);
        for (uint256 k; k < 3; ++k) {
            _claim(b, idx[k]);
        }
        assertEq(usdc.balanceOf(alice), 8_063_437_838);
        assertEq(usdc.balanceOf(carol), 12_095_156_757);
        assertEq(weth.balanceOf(bob), 14_881_989_841_750_378_672);
        // potB = 20_158_594_596; the two floors leave 1 base unit of dust, never a deficit.
        assertEq(usdc.balanceOf(address(router)), 1);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function test_handComputed_allOneDirection_splitsOneSwap() public {
        Spec[] memory specs = _two(_order(alice, true, 20 * E, 0), _order(carol, true, 40 * E, 0));
        (uint256 b, uint256[] memory idx) = _prepare(specs);
        uint256 direct = pair.quote(address(weth), 60 * E);
        assertEq(direct, 112_887_094_034);

        vm.expectEmit(address(router));
        emit BatchRouter.Settled(b, 60 * E, 0, address(weth), 60 * E, direct, 0, direct);
        router.settle(b);
        _claim(b, idx[0]);
        _claim(b, idx[1]);
        assertEq(usdc.balanceOf(alice), 37_629_031_344);
        assertEq(usdc.balanceOf(carol), 75_258_062_689);
        assertEq(usdc.balanceOf(address(router)), 1, "dust");
    }

    function test_handComputed_perfectlyOpposing_noPoolImpact() public {
        Spec[] memory specs =
            _three(_order(alice, true, 3 * E, 0), _order(carol, true, 2 * E, 0), _order(bob, false, 10_000 * U, 0));
        (uint256 b, uint256[] memory idx) = _run(specs);
        for (uint256 k; k < 3; ++k) {
            _claim(b, idx[k]);
        }
        assertEq(usdc.balanceOf(alice), 6_000 * U);
        assertEq(usdc.balanceOf(carol), 4_000 * U);
        assertEq(weth.balanceOf(bob), 5 * E);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // --------------------------------------------------------------------------------------------------------
    // Uniform price and position independence
    // --------------------------------------------------------------------------------------------------------

    /// @dev Netting beats both direct swaps: each side pays less impact than trading alone.
    function test_netting_beatsDirectSwapsForBothSides() public {
        uint256 aliceAlone = pair.quote(address(weth), 10 * E);
        uint256 bobAlone = pair.quote(address(usdc), 30_000 * U);
        (uint256 b, uint256[] memory idx) =
            _run(_two(_order(alice, true, 10 * E, 0), _order(bob, false, 30_000 * U, 0)));
        _claim(b, idx[0]);
        _claim(b, idx[1]);
        assertGt(usdc.balanceOf(alice), aliceAlone);
        assertGt(weth.balanceOf(bob), bobAlone);
    }

    function test_positionIndependence_reversedCommitOrderSamePayouts() public {
        Spec[] memory forward =
            _three(_order(alice, true, 7 * E, 0), _order(carol, false, 9_000 * U, 0), _order(dave, true, 1 * E, 0));
        Spec[] memory backward = _three(forward[2], forward[1], forward[0]);

        uint256 snap = vm.snapshotState();
        (uint256 b1, uint256[] memory i1) = _run(forward);
        uint256[3] memory outs;
        for (uint256 k; k < 3; ++k) {
            outs[k] = router.previewOut(b1, i1[k]);
        }
        vm.revertToState(snap);

        (uint256 b2, uint256[] memory i2) = _run(backward);
        for (uint256 k; k < 3; ++k) {
            assertEq(router.previewOut(b2, i2[2 - k]), outs[k], "same order, same payout, any position");
        }
    }

    // --------------------------------------------------------------------------------------------------------
    // minOut exclusion (D-008, D-016)
    // --------------------------------------------------------------------------------------------------------

    function test_exclusion_exactLimitFillsOneAboveExcludes() public {
        uint256 direct = pair.quote(address(weth), 1 * E);
        assertEq(direct, 1_992_013_962);
        uint256 snap = vm.snapshotState();
        (uint256 b, uint256[] memory idx) = _run(_one(_order(alice, true, 1 * E, direct)));
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Filled));
        vm.revertToState(snap);

        (b, idx) = _prepare(_one(_order(alice, true, 1 * E, direct + 1)));
        vm.expectEmit(address(router));
        emit BatchRouter.OrderExcluded(b, idx[0]);
        router.settle(b);
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Excluded));
    }

    function test_exclusion_excludedOrderRefundedNoPoolSwap() public {
        (uint256 b, uint256[] memory idx) = _prepare(_one(_order(alice, true, 1 * E, 3_000 * U)));
        vm.expectEmit(address(router));
        emit BatchRouter.Settled(b, 0, 0, address(0), 0, 0, 0, 0);
        router.settle(b);
        (uint256 rA,) = pair.getReserves();
        assertEq(rA, RESERVE_A);

        vm.expectEmit(address(router));
        emit BatchRouter.Claimed(b, idx[0], alice, 0, 1 * E, true);
        _claim(b, idx[0]);
        assertEq(weth.balanceOf(alice), 1 * E);
        assertEq(alice.balance, BOND);
    }

    /// @dev X (100 ETH at >= 1990) and Z (1 ETH at >= 1900) both fail at the 101 ETH price. Removing only the
    ///      strictest (X) lets Z fill alone; "exclude every violator at once" would have refunded Z too.
    function test_exclusion_strictestFirstKeepsLooserOrder() public {
        Spec[] memory specs = _two(_order(alice, true, 100 * E, 199_000 * U), _order(carol, true, 1 * E, 1_900 * U));
        (uint256 b, uint256[] memory idx) = _run(specs);
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Excluded));
        assertEq(uint8(_status(b, idx[1])), uint8(BatchRouter.Status.Filled));
        assertEq(router.previewOut(b, idx[1]), 1_992_013_962, "Z gets the direct 1 ETH price");
    }

    /// @dev Two identical 50 ETH orders at >= 1850 each pass alone (~1899) but fail together (~1813). Ties leave
    ///      together, so neither index wins a tie-break; the loose 1 ETH order still fills.
    function test_exclusion_tiesLeaveTogether() public {
        Spec[] memory specs = _three(
            _order(alice, true, 50 * E, 92_500 * U), _order(carol, true, 50 * E, 92_500 * U), _order(dave, true, E, 0)
        );
        (uint256 b, uint256[] memory idx) = _run(specs);
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Excluded));
        assertEq(uint8(_status(b, idx[1])), uint8(BatchRouter.Status.Excluded));
        assertEq(uint8(_status(b, idx[2])), uint8(BatchRouter.Status.Filled));
        assertEq(router.previewOut(b, idx[2]), 1_992_013_962);
    }

    function test_exclusion_bothSidesInOneRound() public {
        Spec[] memory specs = new Spec[](4);
        specs[0] = _order(alice, true, 10 * E, 21_000 * U); // needs 2100/ETH: impossible near 2000
        specs[1] = _order(bob, false, 30_000 * U, 16 * E); // needs 1875 USDC/ETH or better: fails at ~2016
        specs[2] = _order(carol, true, 1 * E, 0);
        specs[3] = _order(dave, false, 1_000 * U, 0);
        (uint256 b, uint256[] memory idx) = _prepare(specs);

        vm.expectEmit(address(router));
        emit BatchRouter.OrderExcluded(b, idx[0]);
        vm.expectEmit(address(router));
        emit BatchRouter.OrderExcluded(b, idx[1]);
        router.settle(b);

        assertEq(uint8(_status(b, idx[2])), uint8(BatchRouter.Status.Filled));
        assertEq(uint8(_status(b, idx[3])), uint8(BatchRouter.Status.Filled));
        BatchRouter.Batch memory batch = router.getBatch(b);
        assertEq(batch.filledInA, 1 * E);
        assertEq(batch.filledInB, 1_000 * U);
    }

    /// @dev 1 wei of WETH quotes 0 USDC, so the residual is dropped and the order would be paid nothing. A zero
    ///      `minOut` counts as 1, so it is excluded and refunded instead of losing its input (D-016).
    function test_exclusion_zeroPayoutNeverFills() public {
        (uint256 b, uint256[] memory idx) = _run(_one(_order(alice, true, 1, 0)));
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Excluded));
        _claim(b, idx[0]);
        assertEq(weth.balanceOf(alice), 1);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function test_exclusion_saturatedMinOutIsExcluded() public {
        (uint256 b, uint256[] memory idx) = _run(_one(_order(alice, true, 1 * E, type(uint256).max)));
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Excluded));
    }

    function test_unrevealedOrderDoesNotMovePrice() public {
        Spec memory hidden = _order(bob, false, 30_000 * U, 0);
        hidden.reveal = false;
        (uint256 b, uint256[] memory idx) = _run(_two(_order(alice, true, 10 * E, 0), hidden));
        assertEq(uint8(_status(b, idx[1])), uint8(BatchRouter.Status.Forfeited));
        assertEq(
            router.previewOut(b, idx[0]),
            _directQuoteAtGenesisReserves(address(weth), 10 * E),
            "alice alone = direct 10 ETH swap"
        );
        assertEq(router.forfeitedBonds(), BOND);
    }

    function _directQuoteAtGenesisReserves(address tokenIn, uint256 amountIn) internal view returns (uint256) {
        return tokenIn == address(weth)
            ? pair.getAmountOut(amountIn, RESERVE_A, RESERVE_B)
            : pair.getAmountOut(amountIn, RESERVE_B, RESERVE_A);
    }

    // --------------------------------------------------------------------------------------------------------
    // Claim and previewOut
    // --------------------------------------------------------------------------------------------------------

    function test_claim_filledPaysOutputRefundsOverEscrowAndBond() public {
        Spec memory s = _order(alice, true, 1 * E, 0);
        s.escrow = 5 * E;
        (uint256 b, uint256[] memory idx) = _run(_one(s));

        vm.expectEmit(address(router));
        emit BatchRouter.Claimed(b, idx[0], alice, 1_992_013_962, 4 * E, true);
        _claim(b, idx[0]);
        assertEq(usdc.balanceOf(alice), 1_992_013_962);
        assertEq(weth.balanceOf(alice), 4 * E);
        assertEq(alice.balance, BOND);

        vm.prank(alice);
        vm.expectRevert(BatchRouter.AlreadyClaimed.selector);
        router.claim(b, idx[0]);
    }

    function test_previewOut_beforeSettleMatchesClaim() public {
        Spec[] memory specs = _two(_order(alice, true, 10 * E, 0), _order(bob, false, 30_000 * U, 0));
        (uint256 b, uint256[] memory idx) = _prepare(specs);
        uint256 previewA = router.previewOut(b, idx[0]);
        uint256 previewB = router.previewOut(b, idx[1]);
        router.settle(b);
        assertEq(router.previewOut(b, idx[0]), previewA);
        _claim(b, idx[0]);
        _claim(b, idx[1]);
        assertEq(usdc.balanceOf(alice), previewA);
        assertEq(weth.balanceOf(bob), previewB);
    }

    function test_previewOut_zeroForUnfilledCases() public {
        Spec memory hidden = _order(bob, false, 1_000 * U, 0);
        hidden.reveal = false;
        Spec[] memory specs = _two(_order(alice, true, 1 * E, 3_000 * U), hidden);
        (uint256 b, uint256[] memory idx) = _prepare(specs);
        assertEq(router.previewOut(b, idx[0]), 0, "would be excluded");
        assertEq(router.previewOut(b, idx[1]), 0, "unrevealed");
        assertEq(router.previewOut(b, 99), 0, "no such order");
        router.settle(b);
        assertEq(router.previewOut(b, idx[0]), 0, "excluded");
        assertEq(router.previewOut(b, idx[1]), 0, "forfeited");
    }

    function test_unseededPool_excludesEverything() public {
        ConstantProductPair empty = new ConstantProductPair(IERC20(address(weth)), IERC20(address(usdc)));
        router = new BatchRouter(empty, treasury, C, R, BOND);
        (uint256 b, uint256[] memory idx) =
            _run(_two(_order(alice, true, 10 * E, 0), _order(bob, false, 20_000 * U, 0)));
        assertEq(uint8(_status(b, idx[0])), uint8(BatchRouter.Status.Excluded));
        assertEq(uint8(_status(b, idx[1])), uint8(BatchRouter.Status.Excluded));
    }

    /// @dev Each order fits uint128, but a side's total may not. Settle reverts rather than overflow a product or
    ///      truncate a stored total (funds stay claimable only after a successful settle: THREAT_MODEL T12).
    function test_settle_revertsWhenSideTotalExceedsUint128() public {
        uint256 max = type(uint128).max;
        (uint256 b,) = _prepare(_two(_order(alice, true, max, 0), _order(carol, true, max, 0)));
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.AmountTooLarge.selector, 2 * max));
        router.settle(b);

        (b,) = _prepare(_two(_order(bob, false, max, 0), _order(dave, false, max, 0)));
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.AmountTooLarge.selector, 2 * max));
        router.settle(b);
    }

    /// @dev XA = uint128.max with enough B to put B in excess: potA = XA + out(r_B) no longer fits uint128.
    function test_settle_revertsWhenPotExceedsUint128() public {
        Spec[] memory specs = _two(_order(alice, true, type(uint128).max, 0), _order(bob, false, 1e30, 0));
        (uint256 b,) = _prepare(specs);
        vm.expectPartialRevert(BatchRouter.AmountTooLarge.selector);
        router.settle(b);
    }

    /// @dev Worst case for the clearing loop: a full batch where every round excludes exactly one order.
    function test_gas_fullBatchWorstCaseExclusion() public {
        Spec[] memory specs = new Spec[](router.MAX_ORDERS_PER_BATCH());
        for (uint256 k; k < specs.length; ++k) {
            // Strictly increasing limit ratios, all unreachable except the loosest few, so the loop peels one per round.
            specs[k] = _order(makeAddr(string(abi.encode(k))), true, 1 * E, 1_800 * U + k * 2 * U);
        }
        (uint256 b,) = _prepare(specs);
        uint256 gasBefore = gasleft();
        router.settle(b);
        uint256 used = gasBefore - gasleft();
        console.log("settle gas, 100 orders, worst-case exclusion:", used);
        assertLt(used, 30_000_000, "fits in a block");
    }

    // --------------------------------------------------------------------------------------------------------
    // Fuzz
    // --------------------------------------------------------------------------------------------------------

    /// @dev Random mixed batches: every fill meets its limit, all fills on a side share one price, both sides see
    ///      the same price within rounding, excluded orders are made whole, and the router ends with dust only.
    function testFuzz_settle_limitsPriceAndConservation(uint256 seed, uint8 n) public {
        Spec[] memory specs = _randomSpecs(seed, bound(n, 1, 16));
        (uint256 b, uint256[] memory idx) = _run(specs);
        BatchRouter.Batch memory batch = router.getBatch(b);

        uint256 filledA;
        uint256 filledB;
        for (uint256 k; k < specs.length; ++k) {
            Spec memory s = specs[k];
            BatchRouter.Status status = _status(b, idx[k]);
            (address tokenIn, address tokenOut) = _tokens(s.aToB);
            _claim(b, idx[k]);
            uint256 got = IERC20(tokenOut).balanceOf(s.user);
            if (status == BatchRouter.Status.Filled) {
                (uint256 pot, uint256 total) = s.aToB ? (batch.potB, batch.filledInA) : (batch.potA, batch.filledInB);
                assertGe(got, s.minOut == 0 ? 1 : s.minOut, "fill below limit");
                assertLe(got * total, s.amountIn * pot, "paid above the uniform price");
                assertGt((got + 1) * total, s.amountIn * pot, "paid below the uniform price");
                if (s.aToB) ++filledA;
                else ++filledB;
            } else {
                assertEq(uint8(status), uint8(BatchRouter.Status.Excluded));
                assertEq(got, 0);
                assertEq(IERC20(tokenIn).balanceOf(s.user), s.amountIn, "excluded order made whole");
            }
            assertEq(s.user.balance, BOND, "bond returned");
        }

        if (filledA > 0 && filledB > 0) {
            (uint256 pA, uint256 pB) = _prices(b);
            assertApproxEqRel(pA, pB, 1e12, "both sides, one price (1e-6)");
        }
        assertLe(weth.balanceOf(address(router)), filledB, "WETH dust < one unit per B-side fill");
        assertLe(usdc.balanceOf(address(router)), filledA, "USDC dust < one unit per A-side fill");
        assertEq(address(router).balance, 0);
    }

    /// @dev The same set of orders committed in a rotated and possibly reversed sequence settles identically.
    function testFuzz_settle_positionIndependent(uint256 seed, uint8 n, uint8 rot, bool reverse) public {
        Spec[] memory specs = _randomSpecs(seed, bound(n, 2, 12));
        uint256 len = specs.length;
        Spec[] memory permuted = new Spec[](len);
        for (uint256 k; k < len; ++k) {
            uint256 from = (k + rot) % len;
            permuted[k] = specs[reverse ? len - 1 - from : from];
        }

        uint256 snap = vm.snapshotState();
        (uint256 b1, uint256[] memory i1) = _run(specs);
        uint256[] memory outs = new uint256[](len);
        uint8[] memory statuses = new uint8[](len);
        for (uint256 k; k < len; ++k) {
            outs[k] = router.previewOut(b1, i1[k]);
            statuses[k] = uint8(_status(b1, i1[k]));
        }
        vm.revertToState(snap);

        (uint256 b2, uint256[] memory i2) = _run(permuted);
        for (uint256 k; k < len; ++k) {
            uint256 from = (k + rot) % len;
            uint256 original = reverse ? len - 1 - from : from;
            assertEq(router.previewOut(b2, i2[k]), outs[original], "payout depends on position");
            assertEq(uint8(_status(b2, i2[k])), statuses[original], "status depends on position");
        }
    }

    /// @dev Orders sized from 0.01 ETH / 10 USDC up to 20% of the pool, with limits between 0 and 110% of spot
    ///      value, so batches mix fills, exclusions, both residual directions and the fee band.
    function _randomSpecs(uint256 seed, uint256 n) internal returns (Spec[] memory specs) {
        specs = new Spec[](n);
        for (uint256 k; k < n; ++k) {
            uint256 h = uint256(keccak256(abi.encode(seed, k)));
            bool aToB = h & 1 == 1;
            uint256 amountIn = aToB ? bound(h >> 8, E / 100, 200 * E) : bound(h >> 8, 10 * U, 400_000 * U);
            uint256 spotValue = aToB ? amountIn * RESERVE_B / RESERVE_A : amountIn * RESERVE_A / RESERVE_B;
            uint256 minOut = spotValue * bound(h >> 128, 0, 1_100) / 1_000;
            specs[k] = _order(makeAddr(string(abi.encode("user", k))), aToB, amountIn, minOut);
        }
    }
}
