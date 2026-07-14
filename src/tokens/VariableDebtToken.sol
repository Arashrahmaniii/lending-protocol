// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Base} from "./ERC20Base.sol";
import {IScaledToken} from "../interfaces/IScaledToken.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {WadRayMath} from "../libraries/WadRayMath.sol";

/**
 * @title VariableDebtToken
 * @notice Non-transferable token tracking a user's variable-rate debt. Balances
 *         are scaled by the reserve's variable borrow index and grow as interest
 *         accrues.
 *
 * @dev Supports credit delegation: a collateral provider can approve another
 *      address to draw debt against their position via `approveDelegation`.
 */
contract VariableDebtToken is ERC20Base, IScaledToken {
    using WadRayMath for uint256;

    event BorrowAllowanceDelegated(
        address indexed fromUser, address indexed toUser, uint256 amount
    );

    ILendingPool public immutable pool;
    address public immutable underlying;

    mapping(address => uint256) internal _scaledBalances;
    uint256 internal _scaledTotalSupply;

    // delegator => delegatee => underlying amount the delegatee may borrow
    mapping(address => mapping(address => uint256)) internal _borrowAllowances;

    modifier onlyPool() {
        require(msg.sender == address(pool), "DebtToken: only pool");
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

    // --------------------------------------------------------------------- //
    //                          Credit delegation                            //
    // --------------------------------------------------------------------- //

    /// @notice Allows `delegatee` to borrow up to `amount` against msg.sender's collateral.
    function approveDelegation(address delegatee, uint256 amount) external {
        _borrowAllowances[msg.sender][delegatee] = amount;
        emit BorrowAllowanceDelegated(msg.sender, delegatee, amount);
    }

    function borrowAllowance(address fromUser, address toUser) external view returns (uint256) {
        return _borrowAllowances[fromUser][toUser];
    }

    /// @notice Consumes delegated borrowing power. Pool-only.
    function decreaseBorrowAllowance(address delegator, address delegatee, uint256 amount)
        external
        onlyPool
    {
        uint256 allowed = _borrowAllowances[delegator][delegatee];
        require(allowed >= amount, "DebtToken: delegation exceeded");
        _borrowAllowances[delegator][delegatee] = allowed - amount;
        emit BorrowAllowanceDelegated(delegator, delegatee, allowed - amount);
    }

    // --------------------------------------------------------------------- //
    //                          Balances / supply                            //
    // --------------------------------------------------------------------- //

    function scaledBalanceOf(address user) public view returns (uint256) {
        return _scaledBalances[user];
    }

    function scaledTotalSupply() public view returns (uint256) {
        return _scaledTotalSupply;
    }

    function balanceOf(address user) public view override returns (uint256) {
        uint256 index = pool.getReserveNormalizedVariableDebt(underlying);
        return _scaledBalances[user].rayMul(index);
    }

    function totalSupply() public view override returns (uint256) {
        uint256 index = pool.getReserveNormalizedVariableDebt(underlying);
        return _scaledTotalSupply.rayMul(index);
    }

    /// @dev Debt is not transferable; ERC20 approve is meaningless here.
    function approve(address, uint256) external pure override returns (bool) {
        revert("DebtToken: operation not supported");
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
        require(scaled != 0, "DebtToken: invalid mint");
        firstMint = _scaledBalances[to] == 0;
        _scaledBalances[to] += scaled;
        _scaledTotalSupply += scaled;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount, uint256 index) external onlyPool {
        uint256 scaled = amount.rayDiv(index);
        require(scaled != 0, "DebtToken: invalid burn");
        _scaledBalances[from] -= scaled;
        _scaledTotalSupply -= scaled;
        emit Transfer(from, address(0), amount);
    }
}
