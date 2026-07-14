// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracle {
    /// @notice Price of `asset` denominated in the base currency, scaled to 1e18 (WAD).
    function getAssetPrice(address asset) external view returns (uint256);
}
