// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Baseline tests for the vendored AMM so later phases build on verified pool math.
contract ConstantProductPairTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    ConstantProductPair internal pair;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    uint256 internal constant POOL_ETH = 1_000e18;
    uint256 internal constant POOL_USDC = 2_000_000e6;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pair = new ConstantProductPair(IERC20(address(weth)), IERC20(address(usdc)));

        weth.mint(lp, POOL_ETH);
        usdc.mint(lp, POOL_USDC);
        vm.startPrank(lp);
        weth.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        pair.addLiquidity(POOL_ETH, POOL_USDC);
        vm.stopPrank();

        vm.prank(trader);
        usdc.approve(address(pair), type(uint256).max);
        vm.prank(trader);
        weth.approve(address(pair), type(uint256).max);
    }

    function _k() internal view returns (uint256) {
        (uint256 r0, uint256 r1) = pair.getReserves();
        return r0 * r1;
    }

    // ---------- constructor ----------

    function test_constructor_revertsOnIdenticalTokens() public {
        vm.expectRevert(ConstantProductPair.IdenticalTokens.selector);
        new ConstantProductPair(IERC20(address(weth)), IERC20(address(weth)));
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(ConstantProductPair.ZeroAddress.selector);
        new ConstantProductPair(IERC20(address(0)), IERC20(address(usdc)));
    }

    // ---------- liquidity ----------

    function test_addLiquidity_firstDepositLocksMinimum() public view {
        uint256 expected = 44_721_359_549_995_793; // sqrt(1000e18 * 2_000_000e6)
        assertEq(pair.sharesOf(lp), expected - pair.MINIMUM_LIQUIDITY());
        assertEq(pair.totalShares(), expected);
        (uint256 r0, uint256 r1) = pair.getReserves();
        assertEq(r0, POOL_ETH);
        assertEq(r1, POOL_USDC);
    }

    function test_removeLiquidity_returnsProRataRoundedDown() public {
        uint256 shares = pair.sharesOf(lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pair.removeLiquidity(shares);
        // The locked MINIMUM_LIQUIDITY keeps a sliver in the pool, so the LP gets slightly less than it put in.
        assertLt(a0, POOL_ETH);
        assertLt(a1, POOL_USDC);
        assertEq(weth.balanceOf(lp), a0);
        (uint256 r0,) = pair.getReserves();
        assertEq(r0, POOL_ETH - a0);
    }

    function test_removeLiquidity_revertsWithoutShares() public {
        vm.prank(trader);
        vm.expectRevert(); // arithmetic underflow
        pair.removeLiquidity(1);
    }

    // ---------- swaps ----------

    /// Matches the Phase 0 model: 100k USDC into a 1,000 ETH / 2M USDC pool gives ~47.4830 ETH.
    function test_swap_matchesPhase0Model() public {
        uint256 amountIn = 100_000e6;
        usdc.mint(trader, amountIn);
        vm.prank(trader);
        uint256 out = pair.swapExactIn(address(usdc), amountIn, 0, trader);
        assertApproxEqAbs(out, 47.4829e18, 0.0001e18);
        assertEq(weth.balanceOf(trader), out);
    }

    function test_swap_outputEqualsFormula() public {
        uint256 amountIn = 3e18;
        weth.mint(trader, amountIn);
        uint256 expected = (amountIn * 997 * POOL_USDC) / (POOL_ETH * 1000 + amountIn * 997);
        vm.prank(trader);
        uint256 out = pair.swapExactIn(address(weth), amountIn, expected, trader);
        assertEq(out, expected);
    }

    function test_swap_revertsBelowMinOut() public {
        uint256 amountIn = 1_000e6;
        usdc.mint(trader, amountIn);
        uint256 quoted = pair.quote(address(usdc), amountIn);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(ConstantProductPair.InsufficientOutput.selector, quoted, quoted + 1));
        pair.swapExactIn(address(usdc), amountIn, quoted + 1, trader);
    }

    function test_swap_revertsOnForeignToken() public {
        address foreign = address(new MockERC20("X", "X", 18));
        vm.expectRevert(abi.encodeWithSelector(ConstantProductPair.InvalidToken.selector, foreign));
        pair.swapExactIn(foreign, 1, 0, trader);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.prank(trader);
        vm.expectRevert(ConstantProductPair.ZeroAmount.selector);
        pair.swapExactIn(address(usdc), 0, 0, trader);
    }

    function test_getAmountOut_revertsOnEmptyReserves() public {
        vm.expectRevert(ConstantProductPair.InsufficientLiquidity.selector);
        pair.getAmountOut(1, 0, 1);
    }

    // ---------- fuzz ----------

    /// k never decreases on a swap (fee and round-down both favour the pool).
    function testFuzz_swap_kNeverDecreases(uint256 amountIn, bool usdcIn) public {
        address tokenIn = usdcIn ? address(usdc) : address(weth);
        amountIn = bound(amountIn, 1e3, usdcIn ? 10_000_000e6 : 10_000e18);
        MockERC20(tokenIn).mint(trader, amountIn);
        uint256 kBefore = _k();
        uint256 expected = pair.quote(tokenIn, amountIn);
        vm.assume(expected > 0);
        vm.prank(trader);
        uint256 out = pair.swapExactIn(tokenIn, amountIn, 0, trader);
        assertEq(out, expected);
        assertGe(_k(), kBefore);
    }

    /// A round trip never makes money: selling what you just bought returns less than you put in.
    function testFuzz_swap_roundTripLoses(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 1_000_000e6);
        usdc.mint(trader, amountIn);
        vm.startPrank(trader);
        uint256 eth = pair.swapExactIn(address(usdc), amountIn, 0, trader);
        uint256 back = pair.swapExactIn(address(weth), eth, 0, trader);
        vm.stopPrank();
        assertLt(back, amountIn);
    }
}
