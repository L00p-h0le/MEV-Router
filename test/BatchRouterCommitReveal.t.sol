// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";
import {BatchRouter} from "../src/BatchRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {ContractUser} from "./mocks/ContractUser.sol";

/// @notice Phase 3 tests: commit, reveal, block windows, bonds, forfeits, refunds (SPEC.md §3-6, D-013).
contract BatchRouterCommitRevealTest is Test {
    MockERC20 internal weth;
    MockERC20 internal usdc;
    ConstantProductPair internal pair;
    BatchRouter internal router;

    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    /// @dev Test parameters chosen in D-014.
    uint64 internal constant C = 10;
    uint64 internal constant R = 5;
    uint256 internal constant BOND = 0.01 ether;
    uint256 internal constant GENESIS = 1_000;

    bytes32 internal constant SALT = keccak256("salt");

    function setUp() public {
        vm.roll(GENESIS);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pair = new ConstantProductPair(IERC20(address(weth)), IERC20(address(usdc)));
        router = new BatchRouter(pair, treasury, C, R, BOND);
    }

    // --------------------------------------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------------------------------------

    function _tokens(bool aToB) internal view returns (address tokenIn, address tokenOut) {
        return aToB ? (address(weth), address(usdc)) : (address(usdc), address(weth));
    }

    function _hash(address user, bool aToB, uint256 amountIn, uint256 minOut, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        (address tokenIn, address tokenOut) = _tokens(aToB);
        return router.computeCommitHash(tokenIn, tokenOut, amountIn, minOut, salt, user);
    }

    function _commit(address user, bool aToB, uint256 escrow, uint256 amountIn, uint256 minOut, bytes32 salt)
        internal
        returns (uint256 batchId, uint256 index)
    {
        (address tokenIn,) = _tokens(aToB);
        MockERC20(tokenIn).mint(user, escrow);
        vm.deal(user, user.balance + BOND);
        vm.startPrank(user);
        IERC20(tokenIn).approve(address(router), escrow);
        (batchId, index) = router.commit{value: BOND}(_hash(user, aToB, amountIn, minOut, salt), tokenIn, escrow);
        vm.stopPrank();
    }

    function _rollToReveal(uint256 batchId) internal {
        (, uint256 revealStart,) = router.batchWindows(batchId);
        vm.roll(revealStart);
    }

    function _rollToSettle(uint256 batchId) internal {
        (,, uint256 revealEnd) = router.batchWindows(batchId);
        vm.roll(revealEnd);
    }

    // --------------------------------------------------------------------------------------------------------
    // Constructor and parameters
    // --------------------------------------------------------------------------------------------------------

    function test_constructor_setsParameters() public view {
        assertEq(address(router.pair()), address(pair));
        assertEq(address(router.tokenA()), address(weth));
        assertEq(address(router.tokenB()), address(usdc));
        assertEq(router.treasury(), treasury);
        assertEq(router.commitBlocks(), C);
        assertEq(router.revealBlocks(), R);
        assertEq(router.bond(), BOND);
        assertEq(router.genesisBlock(), GENESIS);
    }

    function test_constructor_revertsOnZeroPair() public {
        vm.expectRevert(BatchRouter.ZeroAddress.selector);
        new BatchRouter(ConstantProductPair(address(0)), treasury, C, R, BOND);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(BatchRouter.ZeroAddress.selector);
        new BatchRouter(pair, address(0), C, R, BOND);
    }

    function test_constructor_revertsOnZeroWindows() public {
        vm.expectRevert(BatchRouter.InvalidWindow.selector);
        new BatchRouter(pair, treasury, 0, R, BOND);
        vm.expectRevert(BatchRouter.InvalidWindow.selector);
        new BatchRouter(pair, treasury, C, 0, BOND);
    }

    function test_constructor_revertsOnZeroBond() public {
        vm.expectRevert(BatchRouter.ZeroAmount.selector);
        new BatchRouter(pair, treasury, C, R, 0);
    }

    // --------------------------------------------------------------------------------------------------------
    // Windows
    // --------------------------------------------------------------------------------------------------------

    function test_windows_batchBoundaries() public view {
        (uint256 commitStart, uint256 revealStart, uint256 revealEnd) = router.batchWindows(0);
        assertEq(commitStart, GENESIS);
        assertEq(revealStart, GENESIS + C);
        assertEq(revealEnd, GENESIS + C + R);

        (commitStart, revealStart, revealEnd) = router.batchWindows(3);
        assertEq(commitStart, GENESIS + 3 * C);
        assertEq(revealStart, GENESIS + 4 * C);
        assertEq(revealEnd, GENESIS + 4 * C + R);
    }

    function test_windows_currentBatchIdAdvancesEveryCBlocks() public {
        assertEq(router.currentBatchId(), 0);
        vm.roll(GENESIS + C - 1);
        assertEq(router.currentBatchId(), 0);
        vm.roll(GENESIS + C);
        assertEq(router.currentBatchId(), 1);
        vm.roll(GENESIS + 7 * C + 3);
        assertEq(router.currentBatchId(), 7);
    }

    /// @dev Batch k+1 accepts commits while batch k is revealing (SPEC.md §3, overlapping batches).
    function test_windows_nextBatchCommitsWhileCurrentReveals() public {
        (uint256 b0, uint256 i0) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToReveal(b0);
        (uint256 b1,) = _commit(bob, false, 1_000e6, 1_000e6, 0, SALT);
        assertEq(b1, b0 + 1);
        router.reveal(b0, i0, 1e18, 0, SALT);
        assertEq(uint8(router.getOrder(b0, i0).status), uint8(BatchRouter.Status.Revealed));
    }

    // --------------------------------------------------------------------------------------------------------
    // Commit
    // --------------------------------------------------------------------------------------------------------

    function test_commit_storesOrderAndEscrows() public {
        uint256 escrow = 2e18;
        bytes32 h = _hash(alice, true, escrow, 3_000e6, SALT);
        weth.mint(alice, escrow);
        vm.deal(alice, BOND);
        vm.startPrank(alice);
        weth.approve(address(router), escrow);
        vm.expectEmit(address(router));
        emit BatchRouter.Committed(0, 0, alice, address(weth), escrow, h);
        (uint256 batchId, uint256 index) = router.commit{value: BOND}(h, address(weth), escrow);
        vm.stopPrank();

        assertEq(batchId, 0);
        assertEq(index, 0);
        BatchRouter.Order memory o = router.getOrder(0, 0);
        assertEq(o.user, alice);
        assertTrue(o.aToB);
        assertFalse(o.claimed);
        assertEq(uint8(o.status), uint8(BatchRouter.Status.Committed));
        assertEq(o.commitHash, h);
        assertEq(o.escrow, escrow);
        assertEq(o.amountIn, 0);
        assertEq(o.minOut, 0);
        assertEq(router.getBatch(0).orderCount, 1);
        assertEq(weth.balanceOf(address(router)), escrow);
        assertEq(address(router).balance, BOND);
    }

    function test_commit_bToADirection() public {
        (uint256 batchId, uint256 index) = _commit(bob, false, 5_000e6, 5_000e6, 0, SALT);
        assertFalse(router.getOrder(batchId, index).aToB);
        assertEq(usdc.balanceOf(address(router)), 5_000e6);
    }

    function test_commit_indicesIncrementAndBatchFollowsBlock() public {
        (, uint256 i0) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        (, uint256 i1) = _commit(bob, true, 1e18, 1e18, 0, SALT);
        assertEq(i0, 0);
        assertEq(i1, 1);
        vm.roll(GENESIS + C);
        (uint256 b, uint256 i2) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        assertEq(b, 1);
        assertEq(i2, 0);
    }

    function test_commit_revertsOnWrongBond() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.WrongBond.selector, BOND - 1, BOND));
        router.commit{value: BOND - 1}(bytes32(0), address(weth), 1);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.WrongBond.selector, BOND + 1, BOND));
        router.commit{value: BOND + 1}(bytes32(0), address(weth), 1);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.WrongBond.selector, 0, BOND));
        router.commit(bytes32(0), address(weth), 1);
        vm.stopPrank();
    }

    function test_commit_revertsOnForeignToken() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.deal(alice, BOND);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.InvalidToken.selector, address(other)));
        router.commit{value: BOND}(bytes32(0), address(other), 1);
    }

    function test_commit_revertsOnZeroEscrow() public {
        vm.deal(alice, BOND);
        vm.prank(alice);
        vm.expectRevert(BatchRouter.ZeroAmount.selector);
        router.commit{value: BOND}(bytes32(0), address(weth), 0);
    }

    function test_commit_revertsAboveUint128() public {
        uint256 tooLarge = uint256(type(uint128).max) + 1;
        vm.deal(alice, BOND);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.AmountTooLarge.selector, tooLarge));
        router.commit{value: BOND}(bytes32(0), address(weth), tooLarge);
    }

    function test_commit_revertsWhenBatchFull() public {
        uint256 cap = router.MAX_ORDERS_PER_BATCH();
        for (uint256 i; i < cap; ++i) {
            _commit(alice, true, 1, 1, 0, bytes32(i));
        }
        assertEq(router.getBatch(0).orderCount, cap);

        weth.mint(bob, 1);
        vm.deal(bob, BOND);
        vm.startPrank(bob);
        weth.approve(address(router), 1);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.BatchFull.selector, 0));
        router.commit{value: BOND}(bytes32(0), address(weth), 1);
        vm.stopPrank();

        // The next batch is open again.
        vm.roll(GENESIS + C);
        (uint256 b,) = _commit(bob, true, 1, 1, 0, SALT);
        assertEq(b, 1);
    }

    function test_commit_revertsWithoutAllowance() public {
        weth.mint(alice, 1e18);
        vm.deal(alice, BOND);
        vm.prank(alice);
        vm.expectRevert();
        router.commit{value: BOND}(bytes32(0), address(weth), 1e18);
    }

    function test_commit_rejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20();
        ConstantProductPair fotPair = new ConstantProductPair(IERC20(address(fot)), IERC20(address(usdc)));
        BatchRouter fotRouter = new BatchRouter(fotPair, treasury, C, R, BOND);

        fot.mint(alice, 100e18);
        vm.deal(alice, BOND);
        vm.startPrank(alice);
        fot.approve(address(fotRouter), 100e18);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.UnsupportedToken.selector, address(fot)));
        fotRouter.commit{value: BOND}(bytes32(0), address(fot), 100e18);
        vm.stopPrank();
    }

    // --------------------------------------------------------------------------------------------------------
    // Reveal
    // --------------------------------------------------------------------------------------------------------

    function test_reveal_storesAmountsAndEmits() public {
        (uint256 b, uint256 i) = _commit(alice, true, 3e18, 2e18, 3_900e6, SALT);
        _rollToReveal(b);
        vm.expectEmit(address(router));
        emit BatchRouter.Revealed(b, i, 2e18, 3_900e6);
        vm.prank(alice);
        router.reveal(b, i, 2e18, 3_900e6, SALT);

        BatchRouter.Order memory o = router.getOrder(b, i);
        assertEq(uint8(o.status), uint8(BatchRouter.Status.Revealed));
        assertEq(o.amountIn, 2e18);
        assertEq(o.minOut, 3_900e6);
        assertEq(o.escrow, 3e18);
    }

    /// @dev D-006: a keeper with the preimage may reveal; the order still belongs to alice.
    function test_reveal_byThirdParty() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToReveal(b);
        vm.prank(keeper);
        router.reveal(b, i, 1e18, 0, SALT);
        assertEq(router.getOrder(b, i).user, alice);
    }

    function test_reveal_revertsDuringCommitWindow() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        (, uint256 revealStart,) = router.batchWindows(b);
        vm.roll(revealStart - 1);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.NotInRevealWindow.selector, b, revealStart - 1));
        router.reveal(b, i, 1e18, 0, SALT);
    }

    function test_reveal_revertsAtRevealEnd() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        (,, uint256 revealEnd) = router.batchWindows(b);
        vm.roll(revealEnd);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.NotInRevealWindow.selector, b, revealEnd));
        router.reveal(b, i, 1e18, 0, SALT);
    }

    function test_reveal_succeedsOnLastBlock() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        (,, uint256 revealEnd) = router.batchWindows(b);
        vm.roll(revealEnd - 1);
        router.reveal(b, i, 1e18, 0, SALT);
        assertEq(uint8(router.getOrder(b, i).status), uint8(BatchRouter.Status.Revealed));
    }

    function test_reveal_revertsOnDoubleReveal() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToReveal(b);
        router.reveal(b, i, 1e18, 0, SALT);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.BadStatus.selector, BatchRouter.Status.Revealed));
        router.reveal(b, i, 1e18, 0, SALT);
    }

    function test_reveal_revertsOnUnknownIndex() public {
        _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToReveal(0);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.BadStatus.selector, BatchRouter.Status.None));
        router.reveal(0, 1, 1e18, 0, SALT);
    }

    function test_reveal_revertsOnWrongSalt() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToReveal(b);
        vm.expectRevert(BatchRouter.HashMismatch.selector);
        router.reveal(b, i, 1e18, 0, keccak256("other"));
    }

    function test_reveal_revertsOnChangedAmountOrMinOut() public {
        (uint256 b, uint256 i) = _commit(alice, true, 2e18, 1e18, 100, SALT);
        _rollToReveal(b);
        vm.expectRevert(BatchRouter.HashMismatch.selector);
        router.reveal(b, i, 1e18 + 1, 100, SALT);
        vm.expectRevert(BatchRouter.HashMismatch.selector);
        router.reveal(b, i, 1e18, 99, SALT);
    }

    /// @dev The hash was built for B->A but the escrow was posted in A: the direction cannot be switched at reveal.
    function test_reveal_revertsOnDirectionMismatch() public {
        bytes32 h = _hash(alice, false, 1e18, 0, SALT);
        weth.mint(alice, 1e18);
        vm.deal(alice, BOND);
        vm.startPrank(alice);
        weth.approve(address(router), 1e18);
        (uint256 b, uint256 i) = router.commit{value: BOND}(h, address(weth), 1e18);
        vm.stopPrank();
        _rollToReveal(b);
        vm.expectRevert(BatchRouter.HashMismatch.selector);
        router.reveal(b, i, 1e18, 0, SALT);
    }

    /// @dev T10: bob copies alice's public commit hash. His copy binds `user = bob` at reveal, so it never opens.
    function test_reveal_copiedCommitCannotBeOpened() public {
        (uint256 b, uint256 iAlice) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        bytes32 aliceHash = router.getOrder(b, iAlice).commitHash;

        weth.mint(bob, 1e18);
        vm.deal(bob, BOND);
        vm.startPrank(bob);
        weth.approve(address(router), 1e18);
        (, uint256 iBob) = router.commit{value: BOND}(aliceHash, address(weth), 1e18);
        vm.stopPrank();

        _rollToReveal(b);
        router.reveal(b, iAlice, 1e18, 0, SALT);
        vm.expectRevert(BatchRouter.HashMismatch.selector);
        router.reveal(b, iBob, 1e18, 0, SALT);
    }

    /// @dev T10: the same preimage hashes differently on another chain and in another router.
    function test_commitHash_isDomainSeparated() public {
        bytes32 h = _hash(alice, true, 1e18, 0, SALT);
        BatchRouter other = new BatchRouter(pair, treasury, C, R, BOND);
        assertTrue(other.computeCommitHash(address(weth), address(usdc), 1e18, 0, SALT, alice) != h);
        vm.chainId(block.chainid + 1);
        assertTrue(_hash(alice, true, 1e18, 0, SALT) != h);
    }

    function test_commitHash_matchesSpecEncoding() public view {
        bytes32 expected =
            keccak256(abi.encode(block.chainid, address(router), address(weth), address(usdc), 7, 8, SALT, alice));
        assertEq(router.computeCommitHash(address(weth), address(usdc), 7, 8, SALT, alice), expected);
    }

    function test_reveal_revertsOnZeroAmount() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 0, 0, SALT);
        _rollToReveal(b);
        vm.expectRevert(BatchRouter.ZeroAmount.selector);
        router.reveal(b, i, 0, 0, SALT);
    }

    function test_reveal_revertsAboveEscrow() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18 + 1, 0, SALT);
        _rollToReveal(b);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.ExceedsEscrow.selector, 1e18 + 1, 1e18));
        router.reveal(b, i, 1e18 + 1, 0, SALT);
    }

    function test_reveal_saturatesHugeMinOut() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, type(uint256).max, SALT);
        _rollToReveal(b);
        router.reveal(b, i, 1e18, type(uint256).max, SALT);
        assertEq(router.getOrder(b, i).minOut, type(uint128).max);
    }

    // --------------------------------------------------------------------------------------------------------
    // Settle
    // --------------------------------------------------------------------------------------------------------

    function test_settle_revertsBeforeRevealEnd() public {
        (,, uint256 revealEnd) = router.batchWindows(0);
        vm.roll(revealEnd - 1);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.NotSettleable.selector, 0, revealEnd - 1));
        router.settle(0);
    }

    function test_settle_revertsTwice() public {
        _rollToSettle(0);
        router.settle(0);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.AlreadySettled.selector, 0));
        router.settle(0);
    }

    function test_settle_emptyBatchJustMarksSettled() public {
        _rollToSettle(0);
        vm.expectEmit(address(router));
        emit BatchRouter.Settled(0, 0, 0, address(0), 0, 0, 0, 0);
        vm.prank(keeper);
        router.settle(0);
        assertTrue(router.getBatch(0).settled);
        assertEq(router.forfeitedBonds(), 0);
    }

    function test_settle_forfeitsOnlyUnrevealed() public {
        (uint256 b, uint256 iA) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        (, uint256 iB) = _commit(bob, false, 1_000e6, 1_000e6, 0, SALT);
        _rollToReveal(b);
        router.reveal(b, iA, 1e18, 0, SALT);
        _rollToSettle(b);

        vm.expectEmit(address(router));
        emit BatchRouter.OrderForfeited(b, iB);
        router.settle(b);

        assertEq(uint8(router.getOrder(b, iA).status), uint8(BatchRouter.Status.Revealed));
        assertEq(uint8(router.getOrder(b, iB).status), uint8(BatchRouter.Status.Forfeited));
        assertEq(router.forfeitedBonds(), BOND);
    }

    function test_settle_canHappenLongAfterRevealEnd() public {
        _commit(alice, true, 1e18, 1e18, 0, SALT);
        (,, uint256 revealEnd) = router.batchWindows(0);
        vm.roll(revealEnd + 10_000);
        router.settle(0);
        assertTrue(router.getBatch(0).settled);
    }

    // --------------------------------------------------------------------------------------------------------
    // Claim
    // --------------------------------------------------------------------------------------------------------

    function test_claim_revertsBeforeSettle() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToSettle(b);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BatchRouter.NotSettled.selector, b));
        router.claim(b, i);
    }

    function test_claim_revertsForNonOwner() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToSettle(b);
        router.settle(b);
        vm.prank(bob);
        vm.expectRevert(BatchRouter.NotOrderOwner.selector);
        router.claim(b, i);
    }

    function test_claim_revealedRefundsEscrowAndBond() public {
        (uint256 b, uint256 i) = _commit(alice, true, 3e18, 2e18, 0, SALT);
        _rollToReveal(b);
        router.reveal(b, i, 2e18, 0, SALT);
        _rollToSettle(b);
        router.settle(b);

        vm.expectEmit(address(router));
        emit BatchRouter.Claimed(b, i, alice, 0, 3e18, true);
        vm.prank(alice);
        router.claim(b, i);

        assertEq(weth.balanceOf(alice), 3e18);
        assertEq(alice.balance, BOND);
        assertTrue(router.getOrder(b, i).claimed);
    }

    function test_claim_forfeitedRefundsEscrowKeepsBond() public {
        (uint256 b, uint256 i) = _commit(bob, false, 1_000e6, 1_000e6, 0, SALT);
        _rollToSettle(b);
        router.settle(b);

        vm.expectEmit(address(router));
        emit BatchRouter.Claimed(b, i, bob, 0, 1_000e6, false);
        vm.prank(bob);
        router.claim(b, i);

        assertEq(usdc.balanceOf(bob), 1_000e6);
        assertEq(bob.balance, 0);
        assertEq(address(router).balance, BOND);
    }

    function test_claim_revertsTwice() public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToSettle(b);
        router.settle(b);
        vm.startPrank(alice);
        router.claim(b, i);
        vm.expectRevert(BatchRouter.AlreadyClaimed.selector);
        router.claim(b, i);
        vm.stopPrank();
    }

    function test_claim_ethRejectingUserOnlyBlocksItself() public {
        ContractUser cu = new ContractUser(router);
        weth.mint(address(cu), 1e18);
        vm.deal(address(this), BOND);
        (uint256 b, uint256 iCu) = cu.commit{value: BOND}(_hash(address(cu), true, 1e18, 0, SALT), address(weth), 1e18);
        (, uint256 iAlice) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        _rollToReveal(b);
        router.reveal(b, iCu, 1e18, 0, SALT);
        router.reveal(b, iAlice, 1e18, 0, SALT);
        _rollToSettle(b);
        router.settle(b);

        cu.setMode(ContractUser.OnReceive.Reject);
        vm.expectRevert(BatchRouter.EthTransferFailed.selector);
        cu.claim(b, iCu);

        vm.prank(alice);
        router.claim(b, iAlice);
        assertEq(weth.balanceOf(alice), 1e18);

        // Once it accepts ETH again, its claim goes through untouched.
        cu.setMode(ContractUser.OnReceive.Accept);
        cu.claim(b, iCu);
        assertEq(weth.balanceOf(address(cu)), 1e18);
        assertEq(address(cu).balance, BOND);
    }

    /// @dev T9: re-entering `claim` from the bond refund hits the guard, so the outer claim reverts as a whole.
    function test_claim_reentrancyFromBondRefundReverts() public {
        ContractUser cu = new ContractUser(router);
        weth.mint(address(cu), 1e18);
        vm.deal(address(this), BOND);
        (uint256 b, uint256 i) = cu.commit{value: BOND}(_hash(address(cu), true, 1e18, 0, SALT), address(weth), 1e18);
        _rollToReveal(b);
        router.reveal(b, i, 1e18, 0, SALT);
        _rollToSettle(b);
        router.settle(b);

        cu.setMode(ContractUser.OnReceive.Reenter);
        vm.expectRevert(BatchRouter.EthTransferFailed.selector);
        cu.claim(b, i);
        assertFalse(router.getOrder(b, i).claimed);
        assertEq(weth.balanceOf(address(cu)), 0);
    }

    // --------------------------------------------------------------------------------------------------------
    // Forfeits
    // --------------------------------------------------------------------------------------------------------

    function test_withdrawForfeits_paysTreasuryOnly() public {
        _commit(alice, true, 1e18, 1e18, 0, SALT);
        _commit(bob, true, 1e18, 1e18, 0, SALT);
        _rollToSettle(0);
        router.settle(0);
        assertEq(router.forfeitedBonds(), 2 * BOND);

        vm.expectEmit(address(router));
        emit BatchRouter.ForfeitsWithdrawn(treasury, 2 * BOND);
        vm.prank(keeper);
        router.withdrawForfeits();

        assertEq(treasury.balance, 2 * BOND);
        assertEq(keeper.balance, 0);
        assertEq(router.forfeitedBonds(), 0);
    }

    function test_withdrawForfeits_revertsWhenNothingOwed() public {
        vm.expectRevert(BatchRouter.ZeroAmount.selector);
        router.withdrawForfeits();
    }

    // --------------------------------------------------------------------------------------------------------
    // Fuzz
    // --------------------------------------------------------------------------------------------------------

    /// @dev Any valid preimage round-trips: commit, reveal, settle, claim returns exactly what went in.
    function testFuzz_roundTrip_refundsEverything(
        bool aToB,
        uint128 escrow,
        uint128 amountIn,
        uint256 minOut,
        bytes32 salt
    ) public {
        escrow = uint128(bound(escrow, 1, type(uint128).max));
        amountIn = uint128(bound(amountIn, 1, escrow));
        (uint256 b, uint256 i) = _commit(alice, aToB, escrow, amountIn, minOut, salt);
        _rollToReveal(b);
        router.reveal(b, i, amountIn, minOut, salt);
        _rollToSettle(b);
        router.settle(b);
        vm.prank(alice);
        router.claim(b, i);

        (address tokenIn,) = _tokens(aToB);
        assertEq(IERC20(tokenIn).balanceOf(alice), escrow);
        assertEq(alice.balance, BOND);
        assertEq(IERC20(tokenIn).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }

    /// @dev Reveal succeeds exactly inside [revealStart, revealEnd) and nowhere else.
    function testFuzz_reveal_onlyInsideWindow(uint256 offset) public {
        (uint256 b, uint256 i) = _commit(alice, true, 1e18, 1e18, 0, SALT);
        (, uint256 revealStart, uint256 revealEnd) = router.batchWindows(b);
        uint256 blockNumber = bound(offset, GENESIS, revealEnd + 3 * C);
        vm.roll(blockNumber);
        if (blockNumber >= revealStart && blockNumber < revealEnd) {
            router.reveal(b, i, 1e18, 0, SALT);
            assertEq(uint8(router.getOrder(b, i).status), uint8(BatchRouter.Status.Revealed));
        } else {
            vm.expectRevert(abi.encodeWithSelector(BatchRouter.NotInRevealWindow.selector, b, blockNumber));
            router.reveal(b, i, 1e18, 0, SALT);
        }
    }

    /// @dev Mixed reveals and forfeits: after every claim and the treasury withdrawal the router holds nothing, and
    ///      the treasury got exactly one bond per unrevealed order.
    function testFuzz_mixedBatch_conservesFunds(uint8 n, uint256 revealMask) public {
        n = uint8(bound(n, 1, 20));
        address[] memory users = new address[](n);
        uint256 forfeits;
        for (uint256 k; k < n; ++k) {
            users[k] = makeAddr(string(abi.encodePacked("user", k)));
            _commit(users[k], k % 2 == 0, 1_000 + k, 1_000 + k, 0, bytes32(k));
        }
        _rollToReveal(0);
        for (uint256 k; k < n; ++k) {
            if ((revealMask >> k) & 1 == 1) router.reveal(0, k, 1_000 + k, 0, bytes32(k));
            else ++forfeits;
        }
        _rollToSettle(0);
        router.settle(0);
        for (uint256 k; k < n; ++k) {
            vm.prank(users[k]);
            router.claim(0, k);
            (address tokenIn,) = _tokens(k % 2 == 0);
            assertEq(IERC20(tokenIn).balanceOf(users[k]), 1_000 + k);
        }
        assertEq(router.forfeitedBonds(), forfeits * BOND);
        if (forfeits > 0) router.withdrawForfeits();

        assertEq(treasury.balance, forfeits * BOND);
        assertEq(address(router).balance, 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }
}
