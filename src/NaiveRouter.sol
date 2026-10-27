// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";

/// @title NaiveRouter
/// @notice Direct-swap router: every call executes immediately on the pair at whatever price the pool has when the
///         transaction lands. This is the Phase 2 attack baseline, equivalent to a Uniswap V2 router for one pair.
/// @dev Educational reference only, not audited. The only protection is the caller's `minOut`, which is exactly the
///      budget a sandwich attacker spends (see LEARN.md 0.2.5 and 2.2).
contract NaiveRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The pool every swap is routed to.
    ConstantProductPair public immutable pair;

    /// @notice Emitted after every successful swap.
    event Swapped(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address to);

    error ZeroAddress();
    error Expired(uint256 deadline, uint256 timestamp);

    /// @param pair_ The constant-product pair to route through.
    constructor(ConstantProductPair pair_) {
        if (address(pair_) == address(0)) revert ZeroAddress();
        pair = pair_;
    }

    /// @notice Swap an exact input of `tokenIn` for the other pair token. Caller must approve this router first.
    /// @dev The input is measured as this router's balance increase, so a fee-on-transfer token forwards only what
    ///      arrived. The pair re-checks `minOut` and reverts with `InsufficientOutput` below it.
    /// @param tokenIn Token being sold (either pair token; anything else reverts in the pair with `InvalidToken`).
    /// @param amountIn Amount pulled from the caller.
    /// @param minOut Minimum output, the caller's slippage limit.
    /// @param to Recipient of the output.
    /// @param deadline Last `block.timestamp` at which the swap may execute (Uniswap V2 router convention).
    /// @return amountOut Output delivered to `to`.
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        // A deadline only needs coarse time; proposer skew of a few seconds cannot help an attacker here.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        if (to == address(0)) revert ZeroAddress();
        pair.getReservesFor(tokenIn); // reverts with InvalidToken before any transfer for a foreign token

        IERC20 inToken = IERC20(tokenIn);
        uint256 balanceBefore = inToken.balanceOf(address(this));
        inToken.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = inToken.balanceOf(address(this)) - balanceBefore;

        inToken.forceApprove(address(pair), received);
        amountOut = pair.swapExactIn(tokenIn, received, minOut, to);
        emit Swapped(msg.sender, tokenIn, received, amountOut, to);
    }
}
