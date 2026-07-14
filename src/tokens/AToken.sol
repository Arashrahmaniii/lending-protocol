// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Base} from "./ERC20Base.sol";
import {IScaledToken} from "../interfaces/IScaledToken.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";

/**
 * @title AToken
 * @notice Interest-bearing token minted 1:1 (in value) against a deposited
 *         underlying asset. Balances are stored "scaled" (divided by the
 *         reserve's liquidity index); the displayed balance grows over time as
 *         the index grows, which is how depositors earn interest.
 *
 * @dev aTokens are freely transferable, but every transfer is finalized by the
 *      pool, which re-checks the sender's health factor so collateral cannot be
 *      moved out from under an open borrow position.
 */
contract AToken is ERC20Base, IScaledToken {
    using WadRayMath for uint256;

    ILendingPool public immutable pool;
    address public immutable underlying;

    mapping(address => uint256) internal _scaledBalances;
    uint256 internal _scaledTotalSupply;

    modifier onlyPool() {
        require(msg.sender == address(pool), "AToken: only pool");
        _;
    }

    constructor(
        address _pool,
        address _underlying,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20Base(_name, _symbol, _decimals) {
        pool = ILendingPool(_pool);
        underlying = _underlying;
    }

    function scaledBalanceOf(address user) public view returns (uint256) {
        return _scaledBalances[user];
    }

    function scaledTotalSupply() public view returns (uint256) {
        return _scaledTotalSupply;
    }

    function balanceOf(address user) public view override returns (uint256) {
        uint256 index = pool.getReserveNormalizedIncome(underlying);
        return _scaledBalances[user].rayMul(index);
    }

    function totalSupply() public view override returns (uint256) {
        uint256 index = pool.getReserveNormalizedIncome(underlying);
        return _scaledTotalSupply.rayMul(index);
    }

    // --------------------------------------------------------------------- //
    //                          ERC20 transfers                              //
    // --------------------------------------------------------------------- //

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "AToken: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "AToken: to zero");
        uint256 index = pool.getReserveNormalizedIncome(underlying);
        uint256 scaled = amount.rayDiv(index);
        require(scaled != 0, "AToken: invalid amount");

        uint256 fromBefore = _scaledBalances[from];
        uint256 toBefore = _scaledBalances[to];
        require(fromBefore >= scaled, "AToken: balance");

        _scaledBalances[from] = fromBefore - scaled;
        _scaledBalances[to] += scaled;
        emit Transfer(from, to, amount);

        // Pool validates sender health factor and maintains collateral flags.
        pool.finalizeTransfer(underlying, from, to, fromBefore, toBefore);
    }

    // --------------------------------------------------------------------- //
    //                          Pool-only actions                            //
    // --------------------------------------------------------------------- //

    function mint(address to, uint256 amount, uint256 index)
        external
        onlyPool
        returns (bool firstMint)
    {
        uint256 scaled = amount.rayDiv(index);
        require(scaled != 0, "AToken: invalid mint");
        firstMint = _scaledBalances[to] == 0;
        _scaledBalances[to] += scaled;
        _scaledTotalSupply += scaled;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount, uint256 index) external onlyPool {
        uint256 scaled = amount.rayDiv(index);
        require(scaled != 0, "AToken: invalid burn");
        _scaledBalances[from] -= scaled;
        _scaledTotalSupply -= scaled;
        emit Transfer(from, address(0), amount);
    }

    /// @notice Seizes collateral aTokens during liquidation (pool-controlled transfer).
    function transferOnLiquidation(address from, address to, uint256 amount, uint256 index)
        external
        onlyPool
    {
        uint256 scaled = amount.rayDiv(index);
        _scaledBalances[from] -= scaled;
        _scaledBalances[to] += scaled;
        emit Transfer(from, to, amount);
    }

    /// @notice Sends the underlying asset out of the aToken vault. Pool-only.
    function transferUnderlyingTo(address to, uint256 amount) external onlyPool {
        (bool ok, bytes memory data) =
            underlying.call(abi.encodeWithSelector(0xa9059cbb, to, amount)); // transfer(address,uint256)
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "AToken: transfer failed");
    }
}
