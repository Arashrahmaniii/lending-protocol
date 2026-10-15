// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";

/**
 * @notice Regression tests for the 2026-10 self-review:
 *         - share rounding always favours the protocol
 *         - full exits (withdraw max / repay max) clear the position exactly
 *         - repay stays available while the pool is paused
 *         - interest alone can make a position liquidatable, and liquidation works
 *         - dust debt (where the close factor rounds to zero) can still be liquidated
 */
contract HardeningTest is BaseTest {
    uint256 constant T0 = 1_700_000_000;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);
    }

    /// @dev Grows the USDC borrow and liquidity indexes past RAY so rounding is visible.
    function _accrue() internal {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 10_000e6, alice);
        vm.warp(T0 + 365 days);
        // touch the reserve so the stored indexes update
        vm.prank(bob);
        pool.deposit(address(usdc), 1e6, bob);
    }

    // ------------------------------------------------------------------ //
    //                         Rounding direction                          //
    // ------------------------------------------------------------------ //

    function testFuzz_repayNeverClearsMoreDebtThanPaid(uint256 amount) public {
        _accrue();
        uint256 index = pool.getReserveData(address(usdc)).variableBorrowIndex;
        assertGt(index, RAY, "index grew");

        uint256 debt = dUsdc.balanceOf(alice);
        amount = bound(amount, 1, debt - 1);
        usdc.mint(alice, amount);
        vm.prank(alice);
        usdc.approve(address(pool), amount);

        uint256 scaledBefore = dUsdc.scaledBalanceOf(alice);
        vm.prank(alice);
        try pool.repay(address(usdc), amount, alice) {
            uint256 scaledBurned = scaledBefore - dUsdc.scaledBalanceOf(alice);
            // value of the debt cleared, exactly, must not exceed what was paid
            assertLe(scaledBurned * index, amount * RAY, "repay cleared more debt than paid");
        } catch {
            // a repayment too small to clear one scaled unit is rejected, never rounded up
            assertEq(dUsdc.scaledBalanceOf(alice), scaledBefore);
        }
    }

    function testFuzz_borrowRecordsAtLeastTheAmountBorrowed(uint256 amount) public {
        _accrue();
        uint256 index = pool.getReserveData(address(usdc)).variableBorrowIndex;
        (,, uint256 availableBase,,,) = pool.getUserAccountData(alice);
        amount = bound(amount, 1, availableBase / 1e12);

        uint256 scaledBefore = dUsdc.scaledBalanceOf(alice);
        vm.prank(alice);
        pool.borrow(address(usdc), amount, alice);
        uint256 scaledMinted = dUsdc.scaledBalanceOf(alice) - scaledBefore;

        assertGe(scaledMinted * index, amount * RAY, "debt recorded below amount borrowed");
    }

    function testFuzz_supplySharesNeverOverpay(uint256 depositAmount, uint256 withdrawAmount) public {
        _accrue();
        uint256 index = pool.getReserveData(address(usdc)).liquidityIndex;
        assertGt(index, RAY, "liquidity index grew");

        address carol = makeAddr("carol");
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        usdc.mint(carol, depositAmount);
        vm.startPrank(carol);
        usdc.approve(address(pool), depositAmount);
        pool.deposit(address(usdc), depositAmount, carol);
        uint256 scaledMinted = aUsdc.scaledBalanceOf(carol);
        assertLe(scaledMinted * index, depositAmount * RAY, "deposit minted more than paid in");

        uint256 balance = aUsdc.balanceOf(carol);
        withdrawAmount = bound(withdrawAmount, 1, balance - 1);
        pool.withdraw(address(usdc), withdrawAmount, carol);
        vm.stopPrank();
        uint256 scaledBurned = scaledMinted - aUsdc.scaledBalanceOf(carol);
        assertGe(scaledBurned * index, withdrawAmount * RAY, "withdraw burned less than paid out");
    }

    function test_fullRepayAndFullWithdrawClearPositionsExactly() public {
        _accrue();
        usdc.mint(alice, 20_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(address(usdc), type(uint256).max, alice);
        assertEq(dUsdc.scaledBalanceOf(alice), 0, "debt fully cleared");

        pool.withdraw(address(weth), type(uint256).max, alice);
        assertEq(aWeth.scaledBalanceOf(alice), 0, "collateral fully withdrawn");
        vm.stopPrank();

        vm.prank(bob);
        pool.withdraw(address(usdc), type(uint256).max, bob);
        assertEq(aUsdc.scaledBalanceOf(bob), 0, "supplier fully withdrawn");
    }

    // ------------------------------------------------------------------ //
    //                         Pause and liquidation                       //
    // ------------------------------------------------------------------ //

    function test_repayWorksWhilePaused() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 5_000e6, alice);

        pool.setPaused(true);
        vm.warp(T0 + 30 days);

        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(pool), type(uint256).max);
        uint256 debtBefore = dUsdc.balanceOf(alice);
        pool.repay(address(usdc), 1_000e6, alice);
        vm.stopPrank();
        assertLt(dUsdc.balanceOf(alice), debtBefore, "repay reduced debt during pause");

        vm.prank(liquidator);
        vm.expectRevert(bytes("Pool: paused"));
        pool.liquidationCall(address(weth), address(usdc), alice, 1e6, false);
    }

    function test_interestAloneMakesPositionLiquidatable() public {
        // thin USDC liquidity so utilization, and the borrow rate, is high
        vm.prank(bob);
        pool.deposit(address(usdc), 17_000e6, bob);
        vm.prank(alice);
        pool.deposit(address(weth), 10 ether, alice);

        (,, uint256 availableBase,,,) = pool.getUserAccountData(alice);
        vm.prank(alice);
        pool.borrow(address(usdc), availableBase / 1e12, alice); // borrow to max LTV

        vm.warp(T0 + 90 days); // no price change, only interest
        (,,,,, uint256 hf) = pool.getUserAccountData(alice);
        assertLt(hf, 1e18, "interest pushed the position under HF 1");

        vm.prank(liquidator);
        pool.liquidationCall(address(weth), address(usdc), alice, type(uint256).max, false);
        assertGt(weth.balanceOf(liquidator), 0, "liquidator seized collateral");
    }

    function test_dustDebtCanBeLiquidated() public {
        vm.prank(bob);
        pool.deposit(address(usdc), 500_000e6, bob);

        // 2e9 wei WETH of collateral against 1 wei of USDC debt
        vm.startPrank(alice);
        pool.deposit(address(weth), 2e9, alice);
        pool.borrow(address(usdc), 1, alice);
        vm.stopPrank();

        // collateral worth 1.1x the debt: under HF 1, but enough to cover the 5% bonus
        oracle.setAssetPrice(address(weth), 550e18);
        (,,,,, uint256 hf) = pool.getUserAccountData(alice);
        assertLt(hf, 1e18);

        // 50% of 1 wei rounds to 0; before the fix this reverted and the debt was stuck
        vm.prank(liquidator);
        pool.liquidationCall(address(weth), address(usdc), alice, 1, false);
        assertEq(dUsdc.scaledBalanceOf(alice), 0, "dust debt closed");
    }
}
