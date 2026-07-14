// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {WadRayMath} from "./WadRayMath.sol";

/**
 * @title MathUtils
 * @notice Interest accrual helpers. Supply interest accrues linearly, borrow
 *         interest compounds. The compounded formula uses a 3rd-order binomial
 *         expansion (same approach as Aave) which is gas-cheap and accurate for
 *         realistic rates/time deltas.
 */
library MathUtils {
    using WadRayMath for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev Linear interest: 1 + rate * dt / year  (in ray)
    function calculateLinearInterest(uint256 ratePerYear, uint40 lastUpdate)
        internal
        view
        returns (uint256)
    {
        uint256 dt = block.timestamp - uint256(lastUpdate);
        if (dt == 0) return WadRayMath.RAY;
        uint256 accrued = (ratePerYear * dt) / SECONDS_PER_YEAR;
        return WadRayMath.RAY + accrued;
    }

    /// @dev Compounded interest via binomial expansion (in ray).
    function calculateCompoundedInterest(uint256 ratePerYear, uint40 lastUpdate)
        internal
        view
        returns (uint256)
    {
        uint256 dt = block.timestamp - uint256(lastUpdate);
        if (dt == 0) return WadRayMath.RAY;

        uint256 expMinusOne = dt - 1;
        uint256 expMinusTwo = dt > 2 ? dt - 2 : 0;

        uint256 basePowerTwo = ratePerYear.rayMul(ratePerYear) / (SECONDS_PER_YEAR * SECONDS_PER_YEAR);
        uint256 basePowerThree = basePowerTwo.rayMul(ratePerYear) / SECONDS_PER_YEAR;

        uint256 secondTerm = (dt * expMinusOne * basePowerTwo) / 2;
        uint256 thirdTerm = (dt * expMinusOne * expMinusTwo * basePowerThree) / 6;

        uint256 firstTerm = (ratePerYear * dt) / SECONDS_PER_YEAR;

        return WadRayMath.RAY + firstTerm + secondTerm + thirdTerm;
    }
}
