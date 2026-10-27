// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";
import {NaiveRouter} from "../src/NaiveRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Unit tests for the baseline router: it must behave exactly like a direct pair swap.
contract NaiveRouterTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    ConstantProductPair internal pair;
    NaiveRouter internal router;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant POOL_ETH = 1_000e18;
    uint256 internal constant POOL_USDC = 2_000_000e6;

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pair = new ConstantProductPair(IERC20(address(weth)), IERC20(address(usdc)));
        router = new NaiveRouter(pair);

        weth.mint(lp, POOL_ETH);
        usdc.mint(lp, POOL_USDC);
        vm.startPrank(lp);
        weth.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        pair.addLiquidity(POOL_ETH, POOL_USDC);
        vm.stopPrank();

        vm.startPrank(trader);
        weth.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_constructor_revertsOnZeroPair() public {
        vm.expectRevert(NaiveRouter.ZeroAddress.selector);
        new NaiveRouter(ConstantProductPair(address(0)));
    }

    function test_swap_equalsDirectPairQuote() public {
        uint256 amountIn = 100_000e6;
        usdc.mint(trader, amountIn);
        uint256 quoted = pair.quote(address(usdc), amountIn);

        vm.expectEmit(address(router));
        emit NaiveRouter.Swapped(trader, address(usdc), amountIn, quoted, recipient);
        vm.prank(trader);
        uint256 out = router.swapExactIn(address(usdc), amountIn, quoted, recipient, block.timestamp);

        assertEq(out, quoted);
        assertEq(weth.balanceOf(recipient), quoted);
        assertEq(usdc.balanceOf(trader), 0);
    }

    function test_swap_routerKeepsNothing() public {
        uint256 amountIn = 5e18;
        weth.mint(trader, amountIn);
        vm.prank(trader);
        router.swapExactIn(address(weth), amountIn, 0, trader, block.timestamp);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(weth.allowance(address(router), address(pair)), 0);
    }

    function test_swap_revertsBelowMinOut() public {
        uint256 amountIn = 1_000e6;
        usdc.mint(trader, amountIn);
        uint256 quoted = pair.quote(address(usdc), amountIn);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(ConstantProductPair.InsufficientOutput.selector, quoted, quoted + 1));
        router.swapExactIn(address(usdc), amountIn, quoted + 1, trader, block.timestamp);
    }

    function test_swap_revertsAfterDeadline() public {
        uint256 deadline = block.timestamp;
        vm.warp(deadline + 1);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(NaiveRouter.Expired.selector, deadline, deadline + 1));
        router.swapExactIn(address(usdc), 1e6, 0, trader, deadline);
    }

    function test_swap_revertsOnZeroRecipient() public {
        vm.prank(trader);
        vm.expectRevert(NaiveRouter.ZeroAddress.selector);
        router.swapExactIn(address(usdc), 1e6, 0, address(0), block.timestamp);
    }

    function test_swap_revertsOnForeignToken() public {
        address foreign = address(new MockERC20("X", "X", 18));
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(ConstantProductPair.InvalidToken.selector, foreign));
        router.swapExactIn(foreign, 1, 0, trader, block.timestamp);
    }

    function test_swap_revertsOnZeroAmount() public {
        vm.prank(trader);
        vm.expectRevert(ConstantProductPair.ZeroAmount.selector);
        router.swapExactIn(address(usdc), 0, 0, trader, block.timestamp);
    }

    function testFuzz_swap_matchesQuoteBothDirections(uint256 amountIn, bool usdcIn) public {
        address tokenIn = usdcIn ? address(usdc) : address(weth);
        amountIn = bound(amountIn, 1e3, usdcIn ? 10_000_000e6 : 10_000e18);
        MockERC20(tokenIn).mint(trader, amountIn);
        uint256 quoted = pair.quote(tokenIn, amountIn);
        vm.assume(quoted > 0);
        vm.prank(trader);
        uint256 out = router.swapExactIn(tokenIn, amountIn, quoted, trader, block.timestamp);
        assertEq(out, quoted);
    }
}
