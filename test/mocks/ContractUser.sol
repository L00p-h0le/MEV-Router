// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchRouter} from "../../src/BatchRouter.sol";

/// @notice Test-only contract account that trades through the router. Its `receive` can reject ETH or try to re-enter
///         `claim`, to show that a hostile bond recipient only hurts its own claim.
contract ContractUser {
    enum OnReceive {
        Accept,
        Reject,
        Reenter
    }

    error EthRejected();

    BatchRouter internal immutable router;
    OnReceive public mode;
    uint256 internal reenterBatch;
    uint256 internal reenterIndex;

    constructor(BatchRouter router_) {
        router = router_;
    }

    function setMode(OnReceive mode_) external {
        mode = mode_;
    }

    function commit(bytes32 commitHash, address tokenIn, uint256 escrow)
        external
        payable
        returns (uint256 batchId, uint256 index)
    {
        IERC20(tokenIn).approve(address(router), escrow);
        return router.commit{value: msg.value}(commitHash, tokenIn, escrow);
    }

    function claim(uint256 batchId, uint256 index) external {
        reenterBatch = batchId;
        reenterIndex = index;
        router.claim(batchId, index);
    }

    receive() external payable {
        if (mode == OnReceive.Reject) revert EthRejected();
        if (mode == OnReceive.Reenter) router.claim(reenterBatch, reenterIndex);
    }
}
