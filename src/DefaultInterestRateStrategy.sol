// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInterestRateStrategy} from "./interfaces/IInterestRateStrategy.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";

/**
 * @title DefaultInterestRateStrategy
 * @notice Two-slope ("kinked") interest rate model. Below the optimal
 *         utilization the borrow rate rises gently; above it, the rate rises
 *         steeply to incentivise repayment / new deposits and protect liquidity.
 */
contract DefaultInterestRateStrategy is IInterestRateStrategy {
    using WadRayMath for uint256;

    uint256 internal constant BPS = 10_000;

    uint256 public immutable optimalUtilization; // ray
    uint256 public immutable baseVariableBorrowRate; // ray
    uint256 public immutable variableRateSlope1; // ray
    uint256 public immutable variableRateSlope2; // ray

    constructor(
        uint256 _optimalUtilization,
        uint256 _baseVariableBorrowRate,
        uint256 _variableRateSlope1,
        uint256 _variableRateSlope2
    ) {
        optimalUtilization = _optimalUtilization;
        baseVariableBorrowRate = _baseVariableBorrowRate;
        variableRateSlope1 = _variableRateSlope1;
        variableRateSlope2 = _variableRateSlope2;
    }

    function calculateInterestRates(
        uint256 availableLiquidity,
        uint256 totalVariableDebt,
        uint256 reserveFactor
    ) external view returns (uint256 liquidityRate, uint256 variableBorrowRate) {
        uint256 totalDebt = totalVariableDebt;
        uint256 utilization;
        if (totalDebt != 0) {
            uint256 totalLiquidity = availableLiquidity + totalDebt;
            utilization = totalDebt.rayDiv(totalLiquidity);
        }

        if (utilization <= optimalUtilization) {
            uint256 ratio = optimalUtilization == 0 ? 0 : utilization.rayDiv(optimalUtilization);
            variableBorrowRate = baseVariableBorrowRate + variableRateSlope1.rayMul(ratio);
        } else {
            uint256 excess = (utilization - optimalUtilization).rayDiv(WadRayMath.RAY - optimalUtilization);
            variableBorrowRate =
                baseVariableBorrowRate + variableRateSlope1 + variableRateSlope2.rayMul(excess);
        }

        // supply rate = borrow rate * utilization * (1 - reserveFactor)
        uint256 keepShare = ((BPS - reserveFactor) * WadRayMath.RAY) / BPS;
        liquidityRate = variableBorrowRate.rayMul(utilization).rayMul(keepShare);
    }
}
