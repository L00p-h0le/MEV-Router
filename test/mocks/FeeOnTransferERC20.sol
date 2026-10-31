// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only ERC-20 that burns 1% of every transfer (mints are untaxed), to exercise balance-delta checks.
contract FeeOnTransferERC20 is ERC20 {
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant BPS = 10_000;

    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * FEE_BPS / BPS;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
