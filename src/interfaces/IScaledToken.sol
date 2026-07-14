// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IScaledToken {
    function mint(address to, uint256 amount, uint256 index) external returns (bool firstMint);

    function burn(address from, uint256 amount, uint256 index) external;

    function scaledBalanceOf(address user) external view returns (uint256);

    function scaledTotalSupply() external view returns (uint256);
}
