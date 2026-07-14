// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Well-behaved flash-loan receiver: approves repayment of amount + premium.
contract MockFlashLoanReceiver is IFlashLoanReceiver {
    address public immutable pool;
    uint256 public lastAmount;
    uint256 public lastPremium;

    constructor(address _pool) {
        pool = _pool;
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address,
        bytes calldata
    ) external returns (bool) {
        require(msg.sender == pool, "receiver: only pool");
        lastAmount = amount;
        lastPremium = premium;
        // ... arbitrage / liquidation / collateral swap would happen here ...
        MockERC20(asset).approve(pool, amount + premium);
        return true;
    }
}

/// @notice Misbehaving receiver that never approves repayment.
contract MockFlashLoanThief is IFlashLoanReceiver {
    function executeOperation(address, uint256, uint256, address, bytes calldata)
        external
        pure
        returns (bool)
    {
        return true; // claims success but never approves the repayment
    }
}
