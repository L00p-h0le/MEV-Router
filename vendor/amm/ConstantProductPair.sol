// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ConstantProductPair
/// @notice Minimal Uniswap-V2-style x*y=k pool with a 0.3% fee, written fresh as a stand-in for the W2 AMM.
/// @dev Educational reference only, not audited. Liquidity shares are internal balances, not an ERC-20, because
///      the router only needs swaps and tests only need to seed and withdraw liquidity.
contract ConstantProductPair is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fee numerator: 997/1000 means 0.3% of the input stays in the pool.
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;
    /// @notice Shares burned on first deposit so the share price can never be pushed to an extreme (V2 trick).
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint112 private _reserve0;
    uint112 private _reserve1;

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event LiquidityRemoved(address indexed provider, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(
        address indexed sender, address indexed tokenIn, uint256 amountIn, uint256 amountOut, address indexed to
    );

    error IdenticalTokens();
    error ZeroAddress();
    error InvalidToken(address token);
    error ZeroAmount();
    error InsufficientLiquidity();
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error ReserveOverflow();

    /// @param token0_ First token of the pair.
    /// @param token1_ Second token of the pair.
    constructor(IERC20 token0_, IERC20 token1_) {
        if (address(token0_) == address(0) || address(token1_) == address(0)) revert ZeroAddress();
        if (address(token0_) == address(token1_)) revert IdenticalTokens();
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Current reserves of token0 and token1.
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1) {
        return (_reserve0, _reserve1);
    }

    /// @notice Reserves ordered as (reserveIn, reserveOut) for a given input token.
    function getReservesFor(address tokenIn) public view returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == address(token0)) return (_reserve0, _reserve1);
        if (tokenIn == address(token1)) return (_reserve1, _reserve0);
        revert InvalidToken(tokenIn);
    }

    /// @notice Uniswap V2 output formula: dy = dx*997*y / (x*1000 + dx*997). Rounds down (favours the pool).
    /// @param amountIn Input amount.
    /// @param reserveIn Reserve of the input token.
    /// @param reserveOut Reserve of the output token.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        if (amountIn == 0) revert ZeroAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        return Math.mulDiv(amountInWithFee, reserveOut, reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    /// @notice Quote the output for `amountIn` of `tokenIn` at current reserves.
    function quote(address tokenIn, uint256 amountIn) external view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = getReservesFor(tokenIn);
        return getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /// @notice Deposit both tokens and receive pool shares. Caller must approve both tokens first.
    /// @dev First deposit mints sqrt(a0*a1) - MINIMUM_LIQUIDITY; later deposits mint the smaller proportional
    ///      amount, so depositing off-ratio donates the excess to existing LPs (same as V2).
    /// @return shares Shares credited to the caller.
    function addLiquidity(uint256 amount0, uint256 amount1) external nonReentrant returns (uint256 shares) {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);

        uint256 supply = totalShares;
        if (supply == 0) {
            shares = Math.sqrt(amount0 * amount1);
            if (shares <= MINIMUM_LIQUIDITY) revert InsufficientLiquidity();
            shares -= MINIMUM_LIQUIDITY;
            totalShares = MINIMUM_LIQUIDITY; // permanently locked, owned by nobody
        } else {
            shares = Math.min(Math.mulDiv(amount0, supply, _reserve0), Math.mulDiv(amount1, supply, _reserve1));
            if (shares == 0) revert InsufficientLiquidity();
        }
        totalShares += shares;
        sharesOf[msg.sender] += shares;
        _sync();
        emit LiquidityAdded(msg.sender, amount0, amount1, shares);
    }

    /// @notice Burn shares and withdraw the pro-rata reserves (rounded down).
    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert ZeroAmount();
        sharesOf[msg.sender] -= shares; // underflow reverts if caller lacks shares
        uint256 supply = totalShares;
        amount0 = Math.mulDiv(shares, _reserve0, supply);
        amount1 = Math.mulDiv(shares, _reserve1, supply);
        totalShares = supply - shares;
        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
        _sync();
        emit LiquidityRemoved(msg.sender, amount0, amount1, shares);
    }

    /// @notice Swap an exact input for as much output as the curve gives. Caller must approve `tokenIn`.
    /// @dev The input is measured as the balance increase, so a fee-on-transfer token is priced on what arrived.
    /// @param tokenIn Token being sold (token0 or token1).
    /// @param amountIn Amount to pull from the caller.
    /// @param minOut Revert if the output is below this.
    /// @param to Recipient of the output.
    /// @return amountOut Output sent to `to`.
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (to == address(0)) revert ZeroAddress();
        (uint256 reserveIn, uint256 reserveOut) = getReservesFor(tokenIn);
        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = tokenIn == address(token0) ? token1 : token0;

        inToken.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = inToken.balanceOf(address(this)) - reserveIn;
        amountOut = getAmountOut(received, reserveIn, reserveOut);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        outToken.safeTransfer(to, amountOut);
        _sync();
        emit Swap(msg.sender, tokenIn, received, amountOut, to);
    }

    /// @dev Reserves always equal balances after every state change; donations are absorbed on the next sync.
    function _sync() private {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert ReserveOverflow();
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
    }
}
