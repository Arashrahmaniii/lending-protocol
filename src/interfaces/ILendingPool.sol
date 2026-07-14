// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILendingPool {
    function getReserveNormalizedIncome(address asset) external view returns (uint256);

    function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);

    function deposit(address asset, uint256 amount, address onBehalfOf) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function borrow(address asset, uint256 amount, address onBehalfOf) external;

    function repay(address asset, uint256 amount, address onBehalfOf) external returns (uint256);

    function flashLoan(address receiver, address asset, uint256 amount, bytes calldata params) external;

    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

    /// @notice Hook called by aTokens after a transfer to validate the sender's
    ///         health factor and maintain collateral flags.
    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 fromScaledBefore,
        uint256 toScaledBefore
    ) external;

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}
