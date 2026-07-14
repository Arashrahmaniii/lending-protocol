// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/**
 * @title PriceOracle
 * @notice Simple owner-controlled price feed. Prices are denominated in the base
 *         currency and scaled to 1e18. In production this would wrap Chainlink
 *         aggregators (with staleness / min-answer checks); the interface is kept
 *         identical so it can be swapped without touching the pool.
 */
contract PriceOracle is IPriceOracle {
    address public owner;
    mapping(address => uint256) internal _prices;

    event PriceUpdated(address indexed asset, uint256 price);
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

    function setAssetPrice(address asset, uint256 price) external onlyOwner {
        require(price != 0, "Oracle: zero price");
        _prices[asset] = price;
        emit PriceUpdated(asset, price);
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        uint256 price = _prices[asset];
        require(price != 0, "Oracle: no price");
        return price;
    }
}
