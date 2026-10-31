// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";

/// @title BatchRouter
/// @notice Commit-reveal batch router in front of one constant-product pair. Users seal orders in a commit window,
///         open them in the following reveal window, and anyone settles the batch afterwards (SPEC.md §3-6).
/// @dev Educational reference only, not audited. Phase 3 scope: commit, reveal, bonds, block windows, forfeits and
///      refunds. Settlement does not clear yet: a revealed order is refunded in full at claim (D-013). Phase 4 replaces
///      that interim rule with netting, the residual AMM swap and the uniform price.
contract BatchRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on orders per batch, so every loop over a batch is bounded (D-004, re-tuned in Phase 7).
    uint256 public constant MAX_ORDERS_PER_BATCH = 100;

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

    /// @dev The four totals are written by Phase 4 settlement; Phase 3 leaves them zero.
    struct Batch {
        uint32 orderCount;
        bool settled;
        uint128 filledInA;
        uint128 filledInB;
        uint128 potB;
        uint128 potA;
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

    /// @notice Close a batch once its reveal window has ended. Permissionless, callable once.
    /// @dev Phase 3: forfeits every unrevealed order (bond to `forfeitedBonds`) and marks the batch settled. Revealed
    ///      orders keep status `Revealed` and are refunded in full at claim until Phase 4 adds clearing (D-013).
    /// @param batchId Batch to settle.
    function settle(uint256 batchId) external nonReentrant {
        (,, uint256 revealEnd) = batchWindows(batchId);
        if (block.number < revealEnd) revert NotSettleable(batchId, block.number);
        Batch storage batch = _batches[batchId];
        if (batch.settled) revert AlreadySettled(batchId);
        batch.settled = true;

        uint256 count = batch.orderCount;
        uint256 forfeits;
        for (uint256 i; i < count; ++i) {
            Order storage order = _orders[batchId][i];
            if (order.status == Status.Committed) {
                order.status = Status.Forfeited;
                ++forfeits;
                emit OrderForfeited(batchId, i);
            }
        }
        forfeitedBonds += forfeits * bond;

        emit Settled(batchId, 0, 0, address(0), 0, 0, 0, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Claim and forfeits
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Pull everything a settled order is owed. Only the order's owner, once.
    /// @dev Checks-effects-interactions: `claimed` is set before any transfer, and the call is `nonReentrant`.
    ///      A forfeited order gets its escrow back but not its bond (SPEC.md §6, claim table).
    /// @param batchId Batch of the order.
    /// @param index Index of the order.
    function claim(uint256 batchId, uint256 index) external nonReentrant {
        if (!_batches[batchId].settled) revert NotSettled(batchId);
        Order storage order = _orders[batchId][index];
        if (msg.sender != order.user) revert NotOrderOwner();
        if (order.claimed) revert AlreadyClaimed();
        Status status = order.status;
        // Phase 3 has no fills; Revealed is the interim "settled without clearing" state (D-013).
        if (status != Status.Revealed && status != Status.Forfeited) revert BadStatus(status);
        order.claimed = true;

        uint256 refund = order.escrow;
        bool bondReturned = status == Status.Revealed;

        IERC20 inToken = order.aToB ? tokenA : tokenB;
        inToken.safeTransfer(msg.sender, refund);
        if (bondReturned) _sendEth(msg.sender, bond);

        emit Claimed(batchId, index, msg.sender, 0, refund, bondReturned);
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
    // Internal
    // ------------------------------------------------------------------------------------------------------------

    /// @dev True for an A->B order, false for B->A; reverts for any token outside the pair.
    function _direction(address tokenIn) private view returns (bool aToB) {
        if (tokenIn == address(tokenA)) return true;
        if (tokenIn == address(tokenB)) return false;
        revert InvalidToken(tokenIn);
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
