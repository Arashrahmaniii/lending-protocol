// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";

/// @notice Property-based tests over randomized amounts, prices and time.
contract FuzzTest is BaseTest {
    /// @dev Depositing then immediately withdrawing everything returns the exact
    ///      amount (no interest accrued, no value lost to rounding).
    function testFuzz_DepositWithdrawRoundTrip(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);

        vm.startPrank(alice);
        pool.deposit(address(weth), amount, alice);
        uint256 withdrawn = pool.withdraw(address(weth), type(uint256).max, alice);
        vm.stopPrank();

        assertEq(withdrawn, amount, "round trip must be lossless");
        assertEq(weth.balanceOf(alice), 100 ether, "full balance restored");
    }

    /// @dev Any borrow the pool accepts must leave the position healthy, and any
    ///      borrow above the LTV limit must revert.
    function testFuzz_BorrowNeverExceedsLtv(uint256 collateralWeth, uint256 borrowUsdc) public {
        collateralWeth = bound(collateralWeth, 0.01 ether, 100 ether);
        borrowUsdc = bound(borrowUsdc, 1e6, 400_000e6);

        vm.prank(bob);
        pool.deposit(address(usdc), 500_000e6, bob);
        vm.prank(alice);
        pool.deposit(address(weth), collateralWeth, alice);

        // max borrow (base) = collateral value * 80% LTV
        uint256 maxBorrowBase = (collateralWeth * 2000e18 / 1e18) * 8000 / 10_000;
        uint256 borrowBase = uint256(borrowUsdc) * 1e18 / 1e6;

        vm.prank(alice);
        if (borrowBase > maxBorrowBase) {
            vm.expectRevert(bytes("Pool: insufficient collateral"));
            pool.borrow(address(usdc), borrowUsdc, alice);
        } else {
            pool.borrow(address(usdc), borrowUsdc, alice);
            (,,,,, uint256 hf) = pool.getUserAccountData(alice);
            assertGe(hf, 1e18, "accepted borrow must be healthy");
        }
    }

    /// @dev Interest accrual is monotone: debt never shrinks and supplier
    ///      balances never shrink as time passes.
    function testFuzz_InterestIsMonotone(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 1, 5 * 365 days);

        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 10_000e6, alice);

        uint256 debtBefore = dUsdc.balanceOf(alice);
        uint256 supplyBefore = aUsdc.balanceOf(bob);

        vm.warp(block.timestamp + timeDelta);

        assertGe(dUsdc.balanceOf(alice), debtBefore, "debt never decreases");
        assertGe(aUsdc.balanceOf(bob), supplyBefore, "supply never decreases");
    }

    /// @dev Liquidation always reduces debt, and — as long as the collateral is
    ///      still worth more than debt * liquidationBonus — improves the health
    ///      factor. (Below that ratio the bonus mathematically worsens HF; that
    ///      regime exists in Aave too and is why liquidations must be prompt.)
    function testFuzz_LiquidationImprovesHealthFactor(uint256 priceDrop, uint256 debtToCover)
        public
    {
        // HF < 1 requires price < ~1818; collateral/debt > 1.05 requires price > 1575.
        priceDrop = bound(priceDrop, 1600e18, 1800e18);
        debtToCover = bound(debtToCover, 100e6, 7_500e6);

        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 15_000e6, alice);

        oracle.setAssetPrice(address(weth), priceDrop);
        (,,,,, uint256 hfBefore) = pool.getUserAccountData(alice);
        vm.assume(hfBefore < 1e18);
        uint256 debtBefore = dUsdc.balanceOf(alice);

        vm.prank(liquidator);
        pool.liquidationCall(address(weth), address(usdc), alice, debtToCover, false);

        (,,,,, uint256 hfAfter) = pool.getUserAccountData(alice);
        assertLt(dUsdc.balanceOf(alice), debtBefore, "liquidation must reduce debt");
        assertGe(hfAfter, hfBefore, "HF must improve while collateral > debt * bonus");
    }
}
