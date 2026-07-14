// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LendingPool} from "./LendingPool.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {AToken} from "./tokens/AToken.sol";
import {VariableDebtToken} from "./tokens/VariableDebtToken.sol";

/**
 * @title PoolConfigurator
 * @notice Governance-facing entry point for reserve administration: listing new
 *         reserves, updating risk parameters, and swapping interest rate
 *         strategies.
 * @dev Kept as a separate contract from LendingPool (mirroring Aave's
 *      Pool/PoolConfigurator split) so the hot user-facing paths
 *      (deposit/borrow/repay/liquidate/flashLoan) aren't weighed down by the
 *      AToken/VariableDebtToken creation bytecode and config-validation logic,
 *      which only runs on rare admin actions. This keeps LendingPool
 *      comfortably under the EIP-170 24,576-byte runtime size limit with
 *      headroom for future features.
 */
contract PoolConfigurator {
    uint256 internal constant BPS = 10_000;

    LendingPool public immutable pool;
    address public immutable admin;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Configurator: not admin");
        _;
    }

    constructor(address _pool) {
        require(_pool != address(0), "Configurator: zero address");
        pool = LendingPool(_pool);
        admin = msg.sender;
    }

    /// @notice Deploys the aToken/debtToken pair for `asset` and registers the reserve.
    function initReserve(
        address asset,
        DataTypes.ReserveConfig calldata config,
        address interestRateStrategy,
        string calldata assetSymbol
    ) external onlyAdmin returns (address aTokenAddr, address debtTokenAddr) {
        require(asset != address(0) && interestRateStrategy != address(0), "Configurator: zero address");
        _validateReserveConfig(config);

        AToken aToken = new AToken(
            address(pool),
            asset,
            string.concat("Lend Interest Bearing ", assetSymbol),
            string.concat("l", assetSymbol),
            config.decimals
        );
        VariableDebtToken debtToken = new VariableDebtToken(
            address(pool),
            asset,
            string.concat("Lend Variable Debt ", assetSymbol),
            string.concat("d", assetSymbol),
            config.decimals
        );

        pool.initReserve(asset, config, address(aToken), address(debtToken), interestRateStrategy);
        return (address(aToken), address(debtToken));
    }

    /// @notice Updates risk parameters of an existing reserve. Decimals are immutable.
    function updateReserveConfig(address asset, DataTypes.ReserveConfig calldata config)
        external
        onlyAdmin
    {
        DataTypes.ReserveData memory existing = pool.getReserveData(asset);
        require(existing.aTokenAddress != address(0), "Configurator: no reserve");
        require(config.decimals == existing.config.decimals, "Configurator: decimals immutable");
        _validateReserveConfig(config);
        pool.updateReserveConfig(asset, config);
    }

    function setInterestRateStrategy(address asset, address strategy) external onlyAdmin {
        require(strategy != address(0), "Configurator: zero address");
        pool.setInterestRateStrategy(asset, strategy);
    }

    function _validateReserveConfig(DataTypes.ReserveConfig calldata config) internal pure {
        require(config.decimals >= 6 && config.decimals <= 18, "Configurator: bad decimals");
        require(config.ltv <= config.liquidationThreshold, "Configurator: ltv > threshold");
        require(config.liquidationThreshold <= BPS, "Configurator: threshold > 100%");
        require(config.liquidationBonus > BPS, "Configurator: bonus <= 100%");
        // A liquidation must never be able to leave the protocol with bad debt
        // by design: threshold * bonus must stay under 100%.
        require(
            (config.liquidationThreshold * config.liquidationBonus) / BPS <= BPS,
            "Configurator: unsafe threshold/bonus"
        );
        require(config.reserveFactor < BPS, "Configurator: bad reserve factor");
    }
}
