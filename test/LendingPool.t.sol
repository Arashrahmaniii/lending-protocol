// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";

/// @notice Core lifecycle: deposit, withdraw, borrow, repay, interest, liquidation.
contract LendingPoolTest is BaseTest {
    function test_DepositAndWithdraw() public {
        vm.prank(alice);
        pool.deposit(address(weth), 10 ether, alice);

        (uint256 collateral,,,,,) = pool.getUserAccountData(alice);
        assertEq(collateral, 20_000e18, "collateral base should be $20,000");

        vm.prank(alice);
        uint256 withdrawn = pool.withdraw(address(weth), 4 ether, alice);
        assertEq(withdrawn, 4 ether);
        assertEq(weth.balanceOf(alice), 94 ether);
    }

    function test_BorrowRespectsLtv() public {
        _setupLiquidity(); // alice: $20k collateral, 80% LTV => $16k max

        vm.prank(alice);
        vm.expectRevert(bytes("Pool: insufficient collateral"));
        pool.borrow(address(usdc), 16_001e6, alice);

        vm.prank(alice);
        pool.borrow(address(usdc), 16_000e6, alice);
        assertEq(usdc.balanceOf(alice), 16_000e6);
    }

    function test_CannotBorrowAgainstStrangersCollateral() public {
        _setupLiquidity();

        // SECURITY: mallory must not be able to mint debt against alice's WETH.
        address mallory = makeAddr("mallory");
        vm.prank(mallory);
        vm.expectRevert(bytes("DebtToken: delegation exceeded"));
        pool.borrow(address(usdc), 1_000e6, alice);
    }

    function test_InterestAccrues() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 10_000e6, alice);

        uint256 debtBefore = dUsdc.balanceOf(alice);
        uint256 supplyBefore = aUsdc.balanceOf(bob);

        vm.warp(block.timestamp + 365 days);

        assertGt(dUsdc.balanceOf(alice), debtBefore, "debt should grow with interest");
        assertGt(aUsdc.balanceOf(bob), supplyBefore, "supplier earns yield");
    }

    function test_Repay() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 10_000e6, alice);

        usdc.mint(alice, 1_000e6); // cover accrued interest
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);

        vm.warp(block.timestamp + 30 days);
        vm.prank(alice);
        pool.repay(address(usdc), type(uint256).max, alice);

        assertEq(dUsdc.balanceOf(alice), 0, "debt fully repaid");
    }

    function test_LiquidationOnPriceDrop() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 15_000e6, alice); // HF ~ (20000*0.825)/15000 = 1.1

        (,,,,, uint256 hfBefore) = pool.getUserAccountData(alice);
        assertGt(hfBefore, 1e18, "healthy before crash");

        // WETH crashes to $1400 => collateral $14k * 82.5% = 11,550 < 15,000 debt.
        oracle.setAssetPrice(address(weth), 1400e18);
        (,,,,, uint256 hfAfter) = pool.getUserAccountData(alice);
        assertLt(hfAfter, 1e18, "unhealthy after crash");

        uint256 liqWethBefore = weth.balanceOf(liquidator);

        // Liquidator repays up to 50% of debt (7,500 USDC) and seizes WETH + 5% bonus.
        vm.prank(liquidator);
        pool.liquidationCall(address(weth), address(usdc), alice, 7_500e6, false);

        uint256 seized = weth.balanceOf(liquidator) - liqWethBefore;
        // Expected: 7500 USDC / $1400 * 1.05 = 5.625 WETH
        assertApproxEqAbs(seized, 5.625 ether, 0.01 ether, "seized collateral incl. bonus");
        assertApproxEqAbs(dUsdc.balanceOf(alice), 7_500e6, 1e6, "half the debt cleared");
    }

    function test_LiquidationReceivingATokens() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 15_000e6, alice);
        oracle.setAssetPrice(address(weth), 1400e18);

        vm.prank(liquidator);
        pool.liquidationCall(address(weth), address(usdc), alice, 7_500e6, true);

        // Liquidator holds aWETH now, and it counts as their collateral.
        assertApproxEqAbs(aWeth.balanceOf(liquidator), 5.625 ether, 0.01 ether);
        (uint256 liqCollateral,,,,,) = pool.getUserAccountData(liquidator);
        assertGt(liqCollateral, 0, "seized aTokens count as liquidator collateral");
    }

    function test_CannotLiquidateHealthy() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 5_000e6, alice); // very healthy

        vm.prank(liquidator);
        vm.expectRevert(bytes("Pool: position healthy"));
        pool.liquidationCall(address(weth), address(usdc), alice, 1_000e6, false);
    }

    function test_WithdrawBlockedIfItBreaksHealthFactor() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 15_000e6, alice);

        // Withdrawing most collateral would push HF below 1.
        vm.prank(alice);
        vm.expectRevert(bytes("Pool: HF < 1"));
        pool.withdraw(address(weth), 5 ether, alice);
    }

    function test_TreasuryAccruesReserveFactor() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 10_000e6, alice);

        vm.warp(block.timestamp + 365 days);
        pool.mintToTreasury(address(usdc));

        assertGt(aUsdc.balanceOf(treasury), 0, "treasury received its interest cut");
    }
}
