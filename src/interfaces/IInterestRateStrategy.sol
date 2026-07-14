// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInterestRateStrategy {
    /**
     * @notice Computes the new supply and borrow rates for a reserve.
     * @param availableLiquidity underlying tokens idle in the aToken
     * @param totalVariableDebt  total outstanding variable debt
     * @param reserveFactor      bps kept by the protocol treasury
     * @return liquidityRate      per-year supply APR (ray)
     * @return variableBorrowRate per-year borrow APR (ray)
     */
    function calculateInterestRates(
        uint256 availableLiquidity,
        uint256 totalVariableDebt,
        uint256 reserveFactor
    ) external view returns (uint256 liquidityRate, uint256 variableBorrowRate);
}
