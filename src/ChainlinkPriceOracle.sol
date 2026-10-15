// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/**
 * @title ChainlinkPriceOracle
 * @notice Production-grade price source backed by Chainlink aggregators.
 *         Every read is validated for:
 *           - positive answer
 *           - staleness against a per-feed heartbeat
 *         Assets without a feed, and feeds that fail validation (stale, non-positive or
 *         incomplete rounds), fall through to an optional fallback oracle. Without a
 *         fallback, a failing feed reverts with the specific reason.
 *         All prices are normalised to 1e18 (WAD) regardless of feed decimals.
 */
contract ChainlinkPriceOracle is IPriceOracle {
    struct FeedData {
        address aggregator;
        uint48 heartbeat; // max seconds between updates before the price is considered stale
    }

    address public owner;
    IPriceOracle public fallbackOracle;
    mapping(address => FeedData) public feeds;

    event FeedSet(address indexed asset, address indexed aggregator, uint48 heartbeat);
    event FallbackOracleSet(address indexed fallbackOracle);
    event OwnerChanged(address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Oracle: not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Oracle: zero owner");
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    function setFeed(address asset, address aggregator, uint48 heartbeat) external onlyOwner {
        require(aggregator != address(0), "Oracle: zero aggregator");
        require(heartbeat != 0, "Oracle: zero heartbeat");
        feeds[asset] = FeedData(aggregator, heartbeat);
        emit FeedSet(asset, aggregator, heartbeat);
    }

    function setFallbackOracle(address _fallbackOracle) external onlyOwner {
        fallbackOracle = IPriceOracle(_fallbackOracle);
        emit FallbackOracleSet(_fallbackOracle);
    }

    /// @inheritdoc IPriceOracle
    function getAssetPrice(address asset) external view returns (uint256) {
        FeedData memory feed = feeds[asset];

        if (feed.aggregator == address(0)) {
            require(address(fallbackOracle) != address(0), "Oracle: no price source");
            return fallbackOracle.getAssetPrice(asset);
        }

        (uint256 price, string memory failure) = _readFeed(feed);
        if (bytes(failure).length == 0) return price;

        // The primary feed is unusable: use the fallback if one is configured, so that
        // health checks and liquidations keep working through a feed outage.
        require(address(fallbackOracle) != address(0), failure);
        return fallbackOracle.getAssetPrice(asset);
    }

    /// @dev Reads and validates a feed. Returns a non-empty `failure` instead of reverting.
    function _readFeed(FeedData memory feed) internal view returns (uint256 price, string memory failure) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed.aggregator).latestRoundData();

        if (answer <= 0) return (0, "Oracle: invalid answer");
        if (updatedAt == 0) return (0, "Oracle: round not complete");
        if (block.timestamp - updatedAt > feed.heartbeat) return (0, "Oracle: stale price");

        uint8 feedDecimals = AggregatorV3Interface(feed.aggregator).decimals();
        if (feedDecimals <= 18) {
            return (uint256(answer) * 10 ** (18 - feedDecimals), "");
        }
        return (uint256(answer) / 10 ** (feedDecimals - 18), "");
    }
}
