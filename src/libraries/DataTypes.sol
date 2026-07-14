// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library DataTypes {
    struct ReserveConfig {
        uint256 ltv; // loan-to-value in bps (e.g. 7500 = 75%)
        uint256 liquidationThreshold; // bps (e.g. 8000 = 80%)
        uint256 liquidationBonus; // bps > 10000 (e.g. 10500 = 5% bonus)
        uint256 reserveFactor; // bps share of interest kept by protocol
        uint256 supplyCap; // max total supply in underlying units, 0 = unlimited
        uint256 borrowCap; // max total debt in underlying units, 0 = unlimited
        uint8 decimals;
        bool isActive; // reserve fully disabled when false
        bool isFrozen; // frozen: no new deposits/borrows; withdraw/repay/liquidate allowed
        bool borrowingEnabled;
        bool usableAsCollateral;
    }

    struct ReserveData {
        ReserveConfig config;
        uint256 liquidityIndex; // ray, cumulative supply index
        uint256 variableBorrowIndex; // ray, cumulative borrow index
        uint256 currentLiquidityRate; // ray, per-year supply APR
        uint256 currentVariableBorrowRate; // ray, per-year borrow APR
        uint40 lastUpdateTimestamp;
        uint256 accruedToTreasury; // scaled amount owed to treasury
        address aTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategy;
        uint16 id; // index in reservesList
    }
}
