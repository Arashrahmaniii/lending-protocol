// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {PoolConfigurator} from "../src/PoolConfigurator.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {ChainlinkPriceOracle} from "../src/ChainlinkPriceOracle.sol";
import {DefaultInterestRateStrategy} from "../src/DefaultInterestRateStrategy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";

/**
 * @notice Deploys the full protocol with two demo reserves (WETH + USDC),
 *         wired to a Chainlink-style oracle backed by mock aggregators.
 *
 *         anvil &
 *         forge script script/Deploy.s.sol --rpc-url http://localhost:8545 \
 *             --broadcast --private-key <KEY>
 *
 *         On a real network, replace the MockV3Aggregators with the actual
 *         Chainlink feed addresses and drop the MockERC20s.
 */
contract Deploy is Script {
    uint256 constant RAY = 1e27;

    function run() external {
        vm.startBroadcast();

        address treasury = msg.sender;

        // Chainlink-style oracle with staleness checks + mock feeds for local dev.
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle();
        LendingPool pool = new LendingPool(address(oracle), treasury);
        PoolConfigurator configurator = new PoolConfigurator(address(pool));
        pool.setConfigurator(address(configurator));

        // Kinked rate curve: optimal 80%, base 0, slope1 4%, slope2 75% (APR, ray).
        DefaultInterestRateStrategy strategy = new DefaultInterestRateStrategy(
            (80 * RAY) / 100, 0, (4 * RAY) / 100, (75 * RAY) / 100
        );

        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        MockV3Aggregator ethFeed = new MockV3Aggregator(8, 2000e8);
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);
        oracle.setFeed(address(weth), address(ethFeed), 1 hours);
        oracle.setFeed(address(usdc), address(usdcFeed), 24 hours);

        configurator.initReserve(
            address(weth),
            DataTypes.ReserveConfig({
                ltv: 8000,
                liquidationThreshold: 8250,
                liquidationBonus: 10500,
                reserveFactor: 1000,
                supplyCap: 0,
                borrowCap: 0,
                decimals: 18,
                isActive: true,
                isFrozen: false,
                borrowingEnabled: true,
                usableAsCollateral: true
            }),
            address(strategy),
            "WETH"
        );

        configurator.initReserve(
            address(usdc),
            DataTypes.ReserveConfig({
                ltv: 8500,
                liquidationThreshold: 8800,
                liquidationBonus: 10500,
                reserveFactor: 1000,
                supplyCap: 0,
                borrowCap: 0,
                decimals: 6,
                isActive: true,
                isFrozen: false,
                borrowingEnabled: true,
                usableAsCollateral: true
            }),
            address(strategy),
            "USDC"
        );

        console2.log("Oracle:       ", address(oracle));
        console2.log("Pool:         ", address(pool));
        console2.log("Configurator: ", address(configurator));
        console2.log("Strategy:     ", address(strategy));
        console2.log("WETH:     ", address(weth));
        console2.log("USDC:     ", address(usdc));

        vm.stopBroadcast();
    }
}
