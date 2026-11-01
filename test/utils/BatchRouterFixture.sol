// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";
import {BatchRouter} from "../../src/BatchRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture for BatchRouter tests on a seeded pool: 1,000 WETH / 2,000,000 USDC (A = WETH, B = USDC),
///         the SPEC §7 reference pool, with the D-014 parameters. Orders are described declaratively as `Spec`s.
abstract contract BatchRouterFixture is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    ConstantProductPair internal pair;
    BatchRouter internal router;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    uint64 internal constant C = 10;
    uint64 internal constant R = 5;
    uint256 internal constant BOND = 0.01 ether;
    uint256 internal constant GENESIS = 1_000;

    uint256 internal constant E = 1e18;
    uint256 internal constant U = 1e6;
    uint256 internal constant RESERVE_A = 1_000 * E;
    uint256 internal constant RESERVE_B = 2_000_000 * U;

    /// @dev One order of a scenario. `escrow` of 0 means "escrow exactly amountIn".
    struct Spec {
        address user;
        bool aToB;
        uint256 amountIn;
        uint256 minOut;
        uint256 escrow;
        bool reveal;
    }

    function setUp() public virtual {
        vm.roll(GENESIS);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pair = new ConstantProductPair(IERC20(address(weth)), IERC20(address(usdc)));
        router = new BatchRouter(pair, treasury, C, R, BOND);

        address lp = makeAddr("lp");
        weth.mint(lp, RESERVE_A);
        usdc.mint(lp, RESERVE_B);
        vm.startPrank(lp);
        weth.approve(address(pair), RESERVE_A);
        usdc.approve(address(pair), RESERVE_B);
        pair.addLiquidity(RESERVE_A, RESERVE_B);
        vm.stopPrank();
    }

    function _order(address user, bool aToB, uint256 amountIn, uint256 minOut) internal pure returns (Spec memory) {
        return Spec(user, aToB, amountIn, minOut, 0, true);
    }

    function _tokens(bool aToB) internal view returns (address tokenIn, address tokenOut) {
        return aToB ? (address(weth), address(usdc)) : (address(usdc), address(weth));
    }

    function _salt(Spec memory s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s.user, s.amountIn, s.minOut));
    }

    function _commit(Spec memory s) internal returns (uint256 index) {
        (address tokenIn, address tokenOut) = _tokens(s.aToB);
        uint256 escrow = s.escrow == 0 ? s.amountIn : s.escrow;
        MockERC20(tokenIn).mint(s.user, escrow);
        vm.deal(s.user, s.user.balance + BOND);
        bytes32 hash = router.computeCommitHash(tokenIn, tokenOut, s.amountIn, s.minOut, _salt(s), s.user);
        vm.startPrank(s.user);
        IERC20(tokenIn).approve(address(router), escrow);
        (, index) = router.commit{value: BOND}(hash, tokenIn, escrow);
        vm.stopPrank();
    }

    function _reveal(uint256 batchId, uint256 index, Spec memory s) internal {
        router.reveal(batchId, index, s.amountIn, s.minOut, _salt(s));
    }

    /// @dev Commit every order into the current batch, reveal those marked, and roll to the settle block.
    function _prepare(Spec[] memory specs) internal returns (uint256 batchId, uint256[] memory idx) {
        batchId = router.currentBatchId();
        idx = new uint256[](specs.length);
        for (uint256 k; k < specs.length; ++k) {
            idx[k] = _commit(specs[k]);
        }
        (, uint256 revealStart, uint256 revealEnd) = router.batchWindows(batchId);
        vm.roll(revealStart);
        for (uint256 k; k < specs.length; ++k) {
            if (specs[k].reveal) _reveal(batchId, idx[k], specs[k]);
        }
        vm.roll(revealEnd);
    }

    function _run(Spec[] memory specs) internal returns (uint256 batchId, uint256[] memory idx) {
        (batchId, idx) = _prepare(specs);
        router.settle(batchId);
    }

    function _claim(uint256 batchId, uint256 index) internal {
        vm.prank(router.getOrder(batchId, index).user);
        router.claim(batchId, index);
    }

    function _status(uint256 batchId, uint256 index) internal view returns (BatchRouter.Status) {
        return router.getOrder(batchId, index).status;
    }

    function _two(Spec memory x, Spec memory y) internal pure returns (Spec[] memory specs) {
        specs = new Spec[](2);
        (specs[0], specs[1]) = (x, y);
    }

    function _three(Spec memory x, Spec memory y, Spec memory z) internal pure returns (Spec[] memory specs) {
        specs = new Spec[](3);
        (specs[0], specs[1], specs[2]) = (x, y, z);
    }

    function _one(Spec memory x) internal pure returns (Spec[] memory specs) {
        specs = new Spec[](1);
        specs[0] = x;
    }

    /// @dev Uniform price in USDC base units per 1 ETH, as seen by each side.
    function _prices(uint256 batchId) internal view returns (uint256 priceA, uint256 priceB) {
        BatchRouter.Batch memory b = router.getBatch(batchId);
        if (b.filledInA > 0) priceA = Math.mulDiv(b.potB, E, b.filledInA);
        if (b.potA > 0) priceB = Math.mulDiv(b.filledInB, E, b.potA);
    }
}
