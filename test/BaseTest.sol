// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PoolConfigurator} from "../src/PoolConfigurator.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {DefaultInterestRateStrategy} from "../src/DefaultInterestRateStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AToken} from "../src/tokens/AToken.sol";
import {VariableDebtToken} from "../src/tokens/VariableDebtToken.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";

/// @notice Shared deployment + reserve setup for all test suites.
abstract contract BaseTest is Test {
    LendingPool pool;
    PoolConfigurator configurator;
    PriceOracle oracle;
    DefaultInterestRateStrategy strategy;

    MockERC20 weth; // collateral, 18 decimals
    MockERC20 usdc; // borrowable, 6 decimals

    AToken aWeth;
    AToken aUsdc;
    VariableDebtToken dWeth;
    VariableDebtToken dUsdc;

    address alice = makeAddr("alice"); // depositor / borrower
    address bob = makeAddr("bob"); // liquidity provider for USDC
    address liquidator = makeAddr("liquidator");
    address treasury = makeAddr("treasury");

    uint256 constant RAY = 1e27;

    function setUp() public virtual {
        oracle = new PriceOracle();
        pool = new LendingPool(address(oracle), treasury);
        configurator = new PoolConfigurator(address(pool));
        pool.setConfigurator(address(configurator));

        // optimal 80%, base 0%, slope1 4% APR, slope2 75% APR (in ray)
        strategy = new DefaultInterestRateStrategy(
            (80 * RAY) / 100, 0, (4 * RAY) / 100, (75 * RAY) / 100
        );

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Prices in WAD base currency (USD): 1 WETH = $2000, 1 USDC = $1
        oracle.setAssetPrice(address(weth), 2000e18);
        oracle.setAssetPrice(address(usdc), 1e18);

        (address aW, address dW) = _initReserve(address(weth), "WETH", 18, 8000, 8250, 10500, 0, 0);
        (address aU, address dU) = _initReserve(address(usdc), "USDC", 6, 8500, 8800, 10500, 0, 0);
        aWeth = AToken(aW);
        dWeth = VariableDebtToken(dW);
        aUsdc = AToken(aU);
        dUsdc = VariableDebtToken(dU);

        // Seed balances.
        weth.mint(alice, 100 ether);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(liquidator, 1_000_000e6);

        vm.prank(alice);
        weth.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _initReserve(
        address asset,
        string memory symbol,
        uint8 decimals,
        uint256 ltv,
        uint256 threshold,
        uint256 bonus,
        uint256 supplyCap,
        uint256 borrowCap
    ) internal returns (address aToken, address debtToken) {
        DataTypes.ReserveConfig memory cfg = DataTypes.ReserveConfig({
            ltv: ltv,
            liquidationThreshold: threshold,
            liquidationBonus: bonus,
            reserveFactor: 1000, // 10%
            supplyCap: supplyCap,
            borrowCap: borrowCap,
            decimals: decimals,
            isActive: true,
            isFrozen: false,
            borrowingEnabled: true,
            usableAsCollateral: true
        });
        return configurator.initReserve(asset, cfg, address(strategy), symbol);
    }

    /// @dev Standard fixture: bob supplies 500k USDC; alice deposits 10 WETH ($20k).
    function _setupLiquidity() internal {
        vm.prank(bob);
        pool.deposit(address(usdc), 500_000e6, bob);
        vm.prank(alice);
        pool.deposit(address(weth), 10 ether, alice);
    }
}
