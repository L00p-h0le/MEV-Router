// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";

/// @title BatchRouter
/// @notice Commit-reveal batch router in front of one constant-product pair. Users seal orders in a commit window,
///         open them in the following reveal window, and anyone settles the batch afterwards (SPEC.md §3-6).
/// @dev Educational reference only, not audited. Settlement nets opposing flow, swaps only the residual on the pair
///      and pays every filled order, on both sides, one uniform price (SPEC.md §6-7).
contract BatchRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on orders per batch, so every loop over a batch is bounded (D-004, re-tuned in Phase 7).
    uint256 public constant MAX_ORDERS_PER_BATCH = 100;
    /// @dev The pair's fee, 997/1000. Must equal the pair's `FEE_NUMERATOR` / `FEE_DENOMINATOR`; a mismatch breaks
    ///      `test_spec_oneSided_equalsDirectSwap`, which requires a one-order batch to match a direct swap to the wei.
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    /// @notice Lifecycle of one order (SPEC.md §3, order states).
    enum Status {
        None,
        Committed,
        Revealed,
        Filled,
        Excluded,
        Forfeited
    }

    /// @dev Packed into four slots: (user, aToB, claimed, status), commitHash, (escrow, amountIn), minOut.
    struct Order {
        address user;
        bool aToB;
        bool claimed;
        Status status;
        bytes32 commitHash;
        uint128 escrow;
        uint128 amountIn;
        uint128 minOut;
    }

    /// @dev The four totals are written once by `settle`. A filled A->B order is paid `amountIn * potB / filledInA`
    ///      of B, a filled B->A order `amountIn * potA / filledInB` of A, both rounded down.
    struct Batch {
        uint32 orderCount;
        bool settled;
        uint128 filledInA;
        uint128 filledInB;
        uint128 potB;
        uint128 potA;
    }

    /// @dev One order as the clearing loop sees it, copied from storage once. `outcome` starts as `Filled` for a
    ///      revealed order (`Forfeited` otherwise) and may become `Excluded`.
    struct Candidate {
        uint256 amountIn;
        uint256 minOut;
        bool aToB;
        Status outcome;
    }

    /// @dev The clearing result for one set of included orders (SPEC.md §7). `residualAToB` is meaningful only when
    ///      `residualIn > 0`.
    struct Clearing {
        uint256 inA;
        uint256 inB;
        bool residualAToB;
        uint256 residualIn;
        uint256 residualOut;
        uint256 potA;
        uint256 potB;
    }

    /// @notice The pool residual flow is routed to.
    ConstantProductPair public immutable pair;
    /// @notice Token A = `pair.token0()`.
    IERC20 public immutable tokenA;
    /// @notice Token B = `pair.token1()`.
    IERC20 public immutable tokenB;
    /// @notice Sole recipient of forfeited bonds.
    address public immutable treasury;
    /// @notice Length of each batch's commit window, in blocks (C).
    uint64 public immutable commitBlocks;
    /// @notice Length of each batch's reveal window, in blocks (R).
    uint64 public immutable revealBlocks;
    /// @notice ETH every commit must attach; returned unless the order is never revealed.
    uint256 public immutable bond;
    /// @notice `block.number` at deploy; batch 0's commit window starts here.
    uint64 public immutable genesisBlock;

    /// @notice ETH from forfeited bonds, owed to `treasury`.
    uint256 public forfeitedBonds;

    mapping(uint256 batchId => Batch) private _batches;
    mapping(uint256 batchId => mapping(uint256 index => Order)) private _orders;

    event Committed(
        uint256 indexed batchId,
        uint256 indexed index,
        address indexed user,
        address tokenIn,
        uint256 escrow,
        bytes32 commitHash
    );
    event Revealed(uint256 indexed batchId, uint256 indexed index, uint256 amountIn, uint256 minOut);
    event OrderForfeited(uint256 indexed batchId, uint256 indexed index);
    event OrderExcluded(uint256 indexed batchId, uint256 indexed index);
    event Settled(
        uint256 indexed batchId,
        uint256 filledInA,
        uint256 filledInB,
        address residualToken,
        uint256 residualIn,
        uint256 residualOut,
        uint256 potA,
        uint256 potB
    );
    event Claimed(
        uint256 indexed batchId,
        uint256 indexed index,
        address indexed user,
        uint256 amountOut,
        uint256 refund,
        bool bondReturned
    );
    event ForfeitsWithdrawn(address indexed treasury, uint256 amount);

    error WrongBond(uint256 sent, uint256 required);
    error InvalidToken(address token);
    error ZeroAmount();
    error AmountTooLarge(uint256 amount);
    error BatchFull(uint256 batchId);
    error UnsupportedToken(address token);
    error NotInRevealWindow(uint256 batchId, uint256 blockNumber);
    error BadStatus(Status status);
    error HashMismatch();
    error ExceedsEscrow(uint256 amountIn, uint256 escrow);
    error NotSettleable(uint256 batchId, uint256 blockNumber);
    error AlreadySettled(uint256 batchId);
    error NotOrderOwner();
    error NotSettled(uint256 batchId);
    error AlreadyClaimed();
    error ZeroAddress();
    error InvalidWindow();
    error EthTransferFailed();

    /// @param pair_ Pair whose two tokens this router trades.
    /// @param treasury_ Recipient of forfeited bonds.
    /// @param commitBlocks_ Commit window length C, at least 1 block.
    /// @param revealBlocks_ Reveal window length R, at least 1 block.
    /// @param bond_ ETH bond per commit, non-zero.
    constructor(
        ConstantProductPair pair_,
        address treasury_,
        uint64 commitBlocks_,
        uint64 revealBlocks_,
        uint256 bond_
    ) {
        if (address(pair_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (commitBlocks_ == 0 || revealBlocks_ == 0) revert InvalidWindow();
        if (bond_ == 0) revert ZeroAmount();
        pair = pair_;
        tokenA = pair_.token0();
        tokenB = pair_.token1();
        treasury = treasury_;
        commitBlocks = commitBlocks_;
        revealBlocks = revealBlocks_;
        bond = bond_;
        // block.number fits in uint64 for the lifetime of any chain.
        // forge-lint: disable-next-line(unsafe-typecast)
        genesisBlock = uint64(block.number);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Commit
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Seal an order into the current batch, escrowing `escrow` of `tokenIn` and `bond` ETH.
    /// @dev `escrow` may exceed the amount later revealed, so the public escrow need not reveal the true size (D-005).
    ///      The router checks its balance rose by exactly `escrow`; fee-on-transfer tokens are rejected.
    /// @param commitHash `computeCommitHash(tokenIn, tokenOut, amountIn, minOut, salt, msg.sender)`.
    /// @param tokenIn Token being sold, either `tokenA` or `tokenB`.
    /// @param escrow Amount of `tokenIn` pulled now; an upper bound on the revealed `amountIn`.
    /// @return batchId Batch the order joined.
    /// @return index Position of the order inside that batch (used only as an identifier, never for priority).
    function commit(bytes32 commitHash, address tokenIn, uint256 escrow)
        external
        payable
        nonReentrant
        returns (uint256 batchId, uint256 index)
    {
        if (msg.value != bond) revert WrongBond(msg.value, bond);
        bool aToB = _direction(tokenIn);
        if (escrow == 0) revert ZeroAmount();
        if (escrow > type(uint128).max) revert AmountTooLarge(escrow);

        batchId = currentBatchId();
        Batch storage batch = _batches[batchId];
        index = batch.orderCount;
        if (index == MAX_ORDERS_PER_BATCH) revert BatchFull(batchId);

        // index < MAX_ORDERS_PER_BATCH, far below type(uint32).max.
        // forge-lint: disable-next-line(unsafe-typecast)
        batch.orderCount = uint32(index + 1);
        Order storage order = _orders[batchId][index];
        order.user = msg.sender;
        order.aToB = aToB;
        order.status = Status.Committed;
        order.commitHash = commitHash;
        // Checked against type(uint128).max above.
        // forge-lint: disable-next-line(unsafe-typecast)
        order.escrow = uint128(escrow);

        IERC20 inToken = IERC20(tokenIn);
        uint256 balanceBefore = inToken.balanceOf(address(this));
        inToken.safeTransferFrom(msg.sender, address(this), escrow);
        if (inToken.balanceOf(address(this)) - balanceBefore != escrow) revert UnsupportedToken(tokenIn);

        emit Committed(batchId, index, msg.sender, tokenIn, escrow, commitHash);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reveal
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Open a committed order during its batch's reveal window. Callable by anyone holding the preimage.
    /// @dev The hash binds `order.user`, so a third-party revealer cannot redirect anything (D-006). A `minOut` above
    ///      uint128 is stored saturated: no payout can reach it, so the order is excluded rather than stuck.
    /// @param batchId Batch the order was committed to.
    /// @param index Order index returned by `commit`.
    /// @param amountIn True input amount, at most the escrow.
    /// @param minOut Minimum output the owner accepts.
    /// @param salt Secret salt used in the commitment.
    function reveal(uint256 batchId, uint256 index, uint256 amountIn, uint256 minOut, bytes32 salt) external {
        (, uint256 revealStart, uint256 revealEnd) = batchWindows(batchId);
        if (block.number < revealStart || block.number >= revealEnd) {
            revert NotInRevealWindow(batchId, block.number);
        }
        Order storage order = _orders[batchId][index];
        if (order.status != Status.Committed) revert BadStatus(order.status);

        (IERC20 inToken, IERC20 outToken) = order.aToB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 expected = computeCommitHash(address(inToken), address(outToken), amountIn, minOut, salt, order.user);
        if (expected != order.commitHash) revert HashMismatch();
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > order.escrow) revert ExceedsEscrow(amountIn, order.escrow);

        // amountIn <= escrow <= type(uint128).max; minOut is saturated explicitly.
        // forge-lint: disable-next-line(unsafe-typecast)
        order.amountIn = uint128(amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        order.minOut = minOut > type(uint128).max ? type(uint128).max : uint128(minOut);
        order.status = Status.Revealed;

        emit Revealed(batchId, index, amountIn, minOut);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Settle
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Close a batch once its reveal window has ended: forfeit unrevealed orders, exclude orders whose
    ///         `minOut` the uniform price cannot meet, and swap the net residual on the pair. Permissionless, once.
    /// @dev All state is written before the single external call (the residual swap). The swap is given the exact
    ///      quoted output as its minimum, so it returns at least that amount or the whole settle reverts.
    /// @param batchId Batch to settle.
    function settle(uint256 batchId) external nonReentrant {
        (,, uint256 revealEnd) = batchWindows(batchId);
        if (block.number < revealEnd) revert NotSettleable(batchId, block.number);
        Batch storage batch = _batches[batchId];
        if (batch.settled) revert AlreadySettled(batchId);

        (Clearing memory c, Candidate[] memory cands) = _clear(batchId);

        uint256 forfeits;
        for (uint256 i; i < cands.length; ++i) {
            Status outcome = cands[i].outcome;
            _orders[batchId][i].status = outcome;
            if (outcome == Status.Forfeited) {
                ++forfeits;
                emit OrderForfeited(batchId, i);
            } else if (outcome == Status.Excluded) {
                emit OrderExcluded(batchId, i);
            }
        }
        forfeitedBonds += forfeits * bond;

        batch.settled = true;
        // _price caps both totals at uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        batch.filledInA = uint128(c.inA);
        // forge-lint: disable-next-line(unsafe-typecast)
        batch.filledInB = uint128(c.inB);
        batch.potA = _toUint128(c.potA);
        batch.potB = _toUint128(c.potB);

        address residualToken;
        if (c.residualIn > 0) {
            IERC20 inToken = c.residualAToB ? tokenA : tokenB;
            residualToken = address(inToken);
            inToken.forceApprove(address(pair), c.residualIn);
            pair.swapExactIn(residualToken, c.residualIn, c.residualOut, address(this));
        }

        emit Settled(batchId, c.inA, c.inB, residualToken, c.residualIn, c.residualOut, c.potA, c.potB);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Claim and forfeits
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Pull everything a settled order is owed. Only the order's owner, once.
    /// @dev Checks-effects-interactions: `claimed` is set before any transfer, and the call is `nonReentrant`.
    ///      After settle every existing order is Filled, Excluded or Forfeited (SPEC.md §6, claim table); a missing
    ///      index has `user == address(0)` and fails the owner check.
    /// @param batchId Batch of the order.
    /// @param index Index of the order.
    function claim(uint256 batchId, uint256 index) external nonReentrant {
        Batch storage batch = _batches[batchId];
        if (!batch.settled) revert NotSettled(batchId);
        Order storage order = _orders[batchId][index];
        if (msg.sender != order.user) revert NotOrderOwner();
        if (order.claimed) revert AlreadyClaimed();
        order.claimed = true;

        Status status = order.status;
        uint256 refund = order.escrow;
        uint256 amountOut;
        if (status == Status.Filled) {
            amountOut = _filledPayout(batch, order.aToB, order.amountIn);
            refund -= order.amountIn;
        }
        bool bondReturned = status != Status.Forfeited;

        (IERC20 inToken, IERC20 outToken) = order.aToB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (amountOut > 0) outToken.safeTransfer(msg.sender, amountOut);
        if (refund > 0) inToken.safeTransfer(msg.sender, refund);
        if (bondReturned) _sendEth(msg.sender, bond);

        emit Claimed(batchId, index, msg.sender, amountOut, refund, bondReturned);
    }

    /// @notice Send all forfeited bonds to `treasury`, the only possible recipient. Callable by anyone.
    function withdrawForfeits() external nonReentrant {
        uint256 amount = forfeitedBonds;
        if (amount == 0) revert ZeroAmount();
        forfeitedBonds = 0;
        _sendEth(treasury, amount);
        emit ForfeitsWithdrawn(treasury, amount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Batch whose commit window contains the current block.
    function currentBatchId() public view returns (uint256) {
        return (block.number - genesisBlock) / commitBlocks;
    }

    /// @notice Block boundaries of a batch. Commit is [commitStart, revealStart), reveal is [revealStart, revealEnd),
    ///         and settle is allowed from revealEnd on.
    function batchWindows(uint256 batchId)
        public
        view
        returns (uint256 commitStart, uint256 revealStart, uint256 revealEnd)
    {
        commitStart = genesisBlock + batchId * commitBlocks;
        revealStart = commitStart + commitBlocks;
        revealEnd = revealStart + revealBlocks;
    }

    /// @notice The stored order at `(batchId, index)`; all-zero with status `None` if it does not exist.
    function getOrder(uint256 batchId, uint256 index) external view returns (Order memory) {
        return _orders[batchId][index];
    }

    /// @notice The stored batch record.
    function getBatch(uint256 batchId) external view returns (Batch memory) {
        return _batches[batchId];
    }

    /// @notice Output `(batchId, index)` receives in its output token. After settle this is the exact claimable
    ///         output (0 unless Filled). Before settle it simulates settling now, with the orders revealed so far and
    ///         the current reserves, and returns 0 if the order would not be filled.
    function previewOut(uint256 batchId, uint256 index) external view returns (uint256) {
        Batch storage batch = _batches[batchId];
        Order storage order = _orders[batchId][index];
        if (batch.settled) {
            return order.status == Status.Filled ? _filledPayout(batch, order.aToB, order.amountIn) : 0;
        }
        if (order.status != Status.Revealed) return 0;
        (Clearing memory c, Candidate[] memory cands) = _clear(batchId);
        if (cands[index].outcome != Status.Filled) return 0;
        return _payout(c, order.aToB, order.amountIn);
    }

    /// @notice The commitment for an order, domain-separated by chain id and this router's address (D-005).
    /// @dev Uses `abi.encode`, not `abi.encodePacked`, so no two field lists share an encoding.
    function computeCommitHash(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes32 salt,
        address user
    ) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), tokenIn, tokenOut, amountIn, minOut, salt, user));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Clearing (SPEC.md §6 settle steps 2-3, §7)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Load the batch into memory once, then price and exclude until every included order meets its limit.
    ///      Each extra round excludes at least one order, so the loop runs at most `orderCount + 1` times.
    ///      An unseeded pool gives no reference price, so every revealed order is excluded (D-017).
    function _clear(uint256 batchId) private view returns (Clearing memory c, Candidate[] memory cands) {
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();
        Status included = reserveA == 0 || reserveB == 0 ? Status.Excluded : Status.Filled;

        uint256 count = _batches[batchId].orderCount;
        cands = new Candidate[](count);
        for (uint256 i; i < count; ++i) {
            Order storage order = _orders[batchId][i];
            if (order.status == Status.Revealed) {
                cands[i] = Candidate(order.amountIn, order.minOut, order.aToB, included);
            } else {
                cands[i].outcome = Status.Forfeited;
            }
        }

        c = _price(reserveA, reserveB, cands);
        while (_excludeStrictest(c, cands)) {
            c = _price(reserveA, reserveB, cands);
        }
    }

    /// @dev Totals, residual and pots for the currently included orders. The residual is the closed form of SPEC §7,
    ///      rounded down. A residual whose quoted output is zero is dropped, so nothing is swapped for nothing.
    function _price(uint256 reserveA, uint256 reserveB, Candidate[] memory cands)
        private
        view
        returns (Clearing memory c)
    {
        for (uint256 i; i < cands.length; ++i) {
            if (cands[i].outcome != Status.Filled) continue;
            if (cands[i].aToB) c.inA += cands[i].amountIn;
            else c.inB += cands[i].amountIn;
        }
        // Keeps every product below 2^256 (2^10 * 2^112 * 2^128) and lets settle store the totals as uint128.
        if (c.inA > type(uint128).max) revert AmountTooLarge(c.inA);
        if (c.inB > type(uint128).max) revert AmountTooLarge(c.inB);

        // A is in excess when 997*b*XA > 1000*a*XB, B when 997*a*XB > 1000*b*XA; otherwise the batch is in the fee
        // band and clears internally at XB/XA (SPEC §7).
        uint256 excessA = FEE_NUMERATOR * reserveB * c.inA;
        uint256 needA = FEE_DENOMINATOR * reserveA * c.inB;
        uint256 excessB = FEE_NUMERATOR * reserveA * c.inB;
        uint256 needB = FEE_DENOMINATOR * reserveB * c.inA;

        if (excessA > needA) {
            c.residualAToB = true;
            c.residualIn = (excessA - needA) / (FEE_NUMERATOR * (reserveB + c.inB));
            if (c.residualIn > 0) c.residualOut = pair.getAmountOut(c.residualIn, reserveA, reserveB);
        } else if (excessB > needB) {
            c.residualIn = (excessB - needB) / (FEE_NUMERATOR * (reserveA + c.inA));
            if (c.residualIn > 0) c.residualOut = pair.getAmountOut(c.residualIn, reserveB, reserveA);
        }
        if (c.residualOut == 0) c.residualIn = 0;

        if (c.residualIn == 0) {
            (c.potA, c.potB) = (c.inA, c.inB);
        } else if (c.residualAToB) {
            (c.potA, c.potB) = (c.inA - c.residualIn, c.inB + c.residualOut);
        } else {
            (c.potA, c.potB) = (c.inA + c.residualOut, c.inB - c.residualIn);
        }
    }

    /// @dev One exclusion round (D-008). For each side separately, find the strictest limit ratio `minOut/amountIn`
    ///      among orders that miss their limit, and exclude every violator on that side that shares it. Ties leave
    ///      together, so the result depends only on the set of orders, never on their indices.
    /// @return excluded True if any order was excluded, so the caller must re-price.
    function _excludeStrictest(Clearing memory c, Candidate[] memory cands) private pure returns (bool excluded) {
        uint256 none = type(uint256).max;
        uint256 worstA = none;
        uint256 worstB = none;
        for (uint256 i; i < cands.length; ++i) {
            Candidate memory cand = cands[i];
            if (cand.outcome != Status.Filled || _meetsLimit(c, cand)) continue;
            if (cand.aToB) {
                if (worstA == none || _stricter(cand, cands[worstA])) worstA = i;
            } else if (worstB == none || _stricter(cand, cands[worstB])) {
                worstB = i;
            }
        }
        if (worstA == none && worstB == none) return false;

        // Only `outcome` changes below; the reference orders' limits stay readable after they are excluded.
        for (uint256 i; i < cands.length; ++i) {
            Candidate memory cand = cands[i];
            if (cand.outcome != Status.Filled || _meetsLimit(c, cand)) continue;
            uint256 worst = cand.aToB ? worstA : worstB;
            if (!_stricter(cands[worst], cand)) cand.outcome = Status.Excluded;
        }
        return true;
    }

    /// @dev The order is satisfied if its pro-rata payout reaches its limit. A limit of 0 counts as 1: a fill must pay
    ///      something, or its input would be taken for nothing (D-016).
    function _meetsLimit(Clearing memory c, Candidate memory cand) private pure returns (bool) {
        return _payout(c, cand.aToB, cand.amountIn) >= _effectiveMin(cand);
    }

    /// @dev True if `x`'s limit ratio is strictly higher than `y`'s. Cross-multiplied; both products are below 2^256.
    function _stricter(Candidate memory x, Candidate memory y) private pure returns (bool) {
        return _effectiveMin(x) * y.amountIn > _effectiveMin(y) * x.amountIn;
    }

    function _effectiveMin(Candidate memory cand) private pure returns (uint256) {
        return cand.minOut == 0 ? 1 : cand.minOut;
    }

    /// @dev Pro-rata share of the opposite pot, rounded down, so a side never pays out more than its pot holds.
    function _payout(Clearing memory c, bool aToB, uint256 amountIn) private pure returns (uint256) {
        return aToB ? Math.mulDiv(amountIn, c.potB, c.inA) : Math.mulDiv(amountIn, c.potA, c.inB);
    }

    /// @dev `_payout` against the totals stored at settle: the same formula, so a claim equals what settle checked.
    function _filledPayout(Batch storage batch, bool aToB, uint256 amountIn) private view returns (uint256) {
        return
            aToB
                ? Math.mulDiv(amountIn, batch.potB, batch.filledInA)
                : Math.mulDiv(amountIn, batch.potA, batch.filledInB);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------------------

    /// @dev True for an A->B order, false for B->A; reverts for any token outside the pair.
    function _direction(address tokenIn) private view returns (bool aToB) {
        if (tokenIn == address(tokenA)) return true;
        if (tokenIn == address(tokenB)) return false;
        revert InvalidToken(tokenIn);
    }

    /// @dev A pot is at most a side total (uint128) plus the pair's output (below 2^112). That sum can exceed uint128
    ///      only at the very edge of the range, so it is checked rather than assumed.
    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert AmountTooLarge(value);
        // Checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
