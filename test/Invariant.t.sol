// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./BaseTest.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AToken} from "../src/tokens/AToken.sol";
import {VariableDebtToken} from "../src/tokens/VariableDebtToken.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

/**
 * @notice Stateful invariant testing: a handler performs random deposits,
 *         withdrawals, borrows, repays and time warps with three actors, and
 *         after every sequence we assert protocol-level solvency properties.
 */
contract InvariantTest is BaseTest {
    Handler handler;

    function setUp() public override {
        super.setUp();

        handler = new Handler(pool, weth, usdc, aWeth, aUsdc, dWeth, dUsdc);

        // Deep USDC liquidity so borrows in the handler can succeed.
        vm.prank(bob);
        pool.deposit(address(usdc), 500_000e6, bob);

        targetContract(address(handler));
    }

    /// @dev Solvency: for each reserve, cash in the vault plus outstanding debt
    ///      always covers what is owed to suppliers and the treasury.
    function invariant_ReserveSolvency() public view {
        _checkSolvent(address(weth), aWeth, dWeth);
        _checkSolvent(address(usdc), aUsdc, dUsdc);
    }

    function _checkSolvent(address asset, AToken aToken, VariableDebtToken debtToken) internal view {
        uint256 cash = MockERC20(asset).balanceOf(address(aToken));
        uint256 totalDebt = debtToken.totalSupply();
        uint256 owedToSuppliers = aToken.totalSupply();

        // Small tolerance for ray-rounding dust across many operations.
        assertLe(owedToSuppliers, cash + totalDebt + 1e6, "reserve must stay solvent");
    }

    /// @dev The scaled total supply always equals the sum of all actor balances
    ///      (no tokens created or destroyed outside mint/burn).
    function invariant_ScaledSupplyConsistency() public view {
        address[3] memory actors = handler.getActors();

        uint256 sumWeth;
        uint256 sumUsdc;
        for (uint256 i = 0; i < 3; i++) {
            sumWeth += aWeth.scaledBalanceOf(actors[i]);
            sumUsdc += aUsdc.scaledBalanceOf(actors[i]);
        }
        sumWeth += aWeth.scaledBalanceOf(bob) + aWeth.scaledBalanceOf(treasury);
        sumUsdc += aUsdc.scaledBalanceOf(bob) + aUsdc.scaledBalanceOf(treasury);

        assertEq(aWeth.scaledTotalSupply(), sumWeth, "aWETH scaled supply consistent");
        assertEq(aUsdc.scaledTotalSupply(), sumUsdc, "aUSDC scaled supply consistent");
    }

    /// @dev A user's own action (borrow, withdraw) can never leave their position under
    ///      HF 1: the pool must reject it. Accrued interest can still push a position
    ///      under 1 between actions; that is what liquidation is for
    ///      (see HardeningTest.test_interestAloneMakesPositionLiquidatable).
    ///
    ///      An earlier version asserted HF >= 1 for every actor after every sequence.
    ///      That is false: borrowing near max LTV and then warping lets interest pull HF
    ///      below 1 without any price move, so the invariant failed on some seeds.
    function invariant_UserActionsNeverLeavePositionUnderwater() public view {
        assertEq(handler.ghost_actionsLeavingUnhealthy(), 0, "a user action left its own position under HF 1");
    }
}

contract Handler is Test {
    LendingPool pool;
    MockERC20 weth;
    MockERC20 usdc;
    AToken aWeth;
    AToken aUsdc;
    VariableDebtToken dWeth;
    VariableDebtToken dUsdc;

    address[3] public actors;

    /// @dev Successful borrows/withdraws that left the caller under HF 1.
    uint256 public ghost_actionsLeavingUnhealthy;

    constructor(
        LendingPool _pool,
        MockERC20 _weth,
        MockERC20 _usdc,
        AToken _aWeth,
        AToken _aUsdc,
        VariableDebtToken _dWeth,
        VariableDebtToken _dUsdc
    ) {
        pool = _pool;
        weth = _weth;
        usdc = _usdc;
        aWeth = _aWeth;
        aUsdc = _aUsdc;
        dWeth = _dWeth;
        dUsdc = _dUsdc;

        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");

        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(actors[i]);
            weth.approve(address(pool), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function getActors() external view returns (address[3] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0.001 ether, 50 ether);
        weth.mint(actor, amount);
        vm.prank(actor);
        pool.deposit(address(weth), amount, actor);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 balance = aWeth.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(actor);
        try pool.withdraw(address(weth), amount, actor) {
            _recordHealth(actor);
        } catch {}
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        (,, uint256 availableBase,,,) = pool.getUserAccountData(actor);
        if (availableBase < 1e18) return;
        uint256 maxUsdc = availableBase / 1e12; // base(1e18) -> usdc(1e6)
        amount = bound(amount, 1e6, maxUsdc);
        vm.prank(actor);
        try pool.borrow(address(usdc), amount, actor) {
            _recordHealth(actor);
        } catch {}
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 debt = dUsdc.balanceOf(actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        usdc.mint(actor, amount);
        vm.prank(actor);
        try pool.repay(address(usdc), amount, actor) {} catch {}
    }

    function _recordHealth(address actor) internal {
        (,,,,, uint256 hf) = pool.getUserAccountData(actor);
        if (hf < 1e18) ghost_actionsLeavingUnhealthy++;
    }

    function warp(uint256 timeDelta) external {
        timeDelta = bound(timeDelta, 1 hours, 30 days);
        vm.warp(block.timestamp + timeDelta);
    }
}
