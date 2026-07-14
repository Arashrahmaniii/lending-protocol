// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceOracle} from "../src/ChainlinkPriceOracle.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract ChainlinkOracleTest is Test {
    ChainlinkPriceOracle oracle;
    MockV3Aggregator ethFeed; // 8 decimals like real Chainlink USD feeds
    address weth = makeAddr("weth");

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new ChainlinkPriceOracle();
        ethFeed = new MockV3Aggregator(8, 2000e8); // $2000, 8 decimals
        oracle.setFeed(weth, address(ethFeed), 1 hours);
    }

    function test_ScalesFeedDecimalsToWad() public view {
        assertEq(oracle.getAssetPrice(weth), 2000e18, "8-decimal feed scaled to 1e18");
    }

    function test_RevertsOnStalePrice() public {
        vm.warp(block.timestamp + 2 hours); // heartbeat is 1 hour
        vm.expectRevert(bytes("Oracle: stale price"));
        oracle.getAssetPrice(weth);
    }

    function test_FreshUpdateClearsStaleness() public {
        vm.warp(block.timestamp + 2 hours);
        ethFeed.updateAnswer(1900e8);
        assertEq(oracle.getAssetPrice(weth), 1900e18);
    }

    function test_RevertsOnNegativeOrZeroAnswer() public {
        ethFeed.updateAnswer(0);
        vm.expectRevert(bytes("Oracle: invalid answer"));
        oracle.getAssetPrice(weth);

        ethFeed.updateAnswer(-1);
        vm.expectRevert(bytes("Oracle: invalid answer"));
        oracle.getAssetPrice(weth);
    }

    function test_FallbackOracleUsedWhenNoFeed() public {
        address dai = makeAddr("dai");

        vm.expectRevert(bytes("Oracle: no price source"));
        oracle.getAssetPrice(dai);

        PriceOracle fallbackOracle = new PriceOracle();
        fallbackOracle.setAssetPrice(dai, 1e18);
        oracle.setFallbackOracle(address(fallbackOracle));

        assertEq(oracle.getAssetPrice(dai), 1e18, "falls through to fallback");
    }

    function test_OnlyOwnerCanSetFeed() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes("Oracle: not owner"));
        oracle.setFeed(weth, address(ethFeed), 1 hours);
    }
}
