// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Credit delegation, caps, pause/freeze, aToken transfers, collateral
///         toggling and admin config validation.
contract FeaturesTest is BaseTest {
    // ------------------------------ Credit delegation ------------------------------ //

    function test_CreditDelegation() public {
        _setupLiquidity();
        address delegatee = makeAddr("delegatee");

        // Alice delegates 5,000 USDC of her borrowing power to delegatee.
        vm.prank(alice);
        dUsdc.approveDelegation(delegatee, 5_000e6);
        assertEq(dUsdc.borrowAllowance(alice, delegatee), 5_000e6);

        // Delegatee draws 3,000 — funds go to delegatee, debt goes to alice.
        vm.prank(delegatee);
        pool.borrow(address(usdc), 3_000e6, alice);
        assertEq(usdc.balanceOf(delegatee), 3_000e6);
        assertEq(dUsdc.balanceOf(alice), 3_000e6);
        assertEq(dUsdc.borrowAllowance(alice, delegatee), 2_000e6, "allowance consumed");

        // Exceeding the remaining allowance reverts.
        vm.prank(delegatee);
        vm.expectRevert(bytes("DebtToken: delegation exceeded"));
        pool.borrow(address(usdc), 2_001e6, alice);
    }

    // ------------------------------ Supply / borrow caps ------------------------------ //

    function test_SupplyCap() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        oracle.setAssetPrice(address(dai), 1e18);
        _initReserve(address(dai), "DAI", 18, 7500, 8000, 10500, 1_000e18, 0);

        dai.mint(alice, 2_000e18);
        vm.startPrank(alice);
        dai.approve(address(pool), type(uint256).max);
        pool.deposit(address(dai), 900e18, alice);

        vm.expectRevert(bytes("Pool: supply cap"));
        pool.deposit(address(dai), 200e18, alice); // 900 + 200 > 1000 cap
        vm.stopPrank();
    }

    function test_BorrowCap() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        oracle.setAssetPrice(address(dai), 1e18);
        _initReserve(address(dai), "DAI", 18, 7500, 8000, 10500, 0, 1_000e18);

        dai.mint(bob, 10_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.deposit(address(dai), 10_000e18, bob);
        vm.stopPrank();

        vm.startPrank(alice);
        pool.deposit(address(weth), 10 ether, alice);
        vm.expectRevert(bytes("Pool: borrow cap"));
        pool.borrow(address(dai), 1_001e18, alice);

        pool.borrow(address(dai), 1_000e18, alice); // exactly at the cap is fine
        vm.stopPrank();
    }

    // ------------------------------ Pause / freeze ------------------------------ //

    function test_PauseBlocksAllActions() public {
        _setupLiquidity();

        pool.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(bytes("Pool: paused"));
        pool.deposit(address(weth), 1 ether, alice);
        vm.expectRevert(bytes("Pool: paused"));
        pool.withdraw(address(weth), 1 ether, alice);
        vm.expectRevert(bytes("Pool: paused"));
        pool.borrow(address(usdc), 100e6, alice);
        vm.stopPrank();

        pool.setPaused(false);
        vm.prank(alice);
        pool.withdraw(address(weth), 1 ether, alice); // works again
    }

    function test_OnlyAdminsCanPause() public {
        vm.prank(alice);
        vm.expectRevert(bytes("Pool: not authorized"));
        pool.setPaused(true);
    }

    function test_FrozenReserveBlocksNewExposureOnly() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 5_000e6, alice);

        // Freeze WETH.
        DataTypes.ReserveConfig memory cfg = pool.getReserveData(address(weth)).config;
        cfg.isFrozen = true;
        pool.updateReserveConfig(address(weth), cfg);

        vm.startPrank(alice);
        vm.expectRevert(bytes("Pool: reserve frozen"));
        pool.deposit(address(weth), 1 ether, alice);

        // But withdrawing existing collateral still works.
        pool.withdraw(address(weth), 1 ether, alice);
        vm.stopPrank();
    }

    // ------------------------------ aToken transfers ------------------------------ //

    function test_ATokenTransfer() public {
        _setupLiquidity();
        address carol = makeAddr("carol");

        vm.prank(alice);
        aWeth.transfer(carol, 3 ether);

        assertEq(aWeth.balanceOf(carol), 3 ether);
        (uint256 carolCollateral,,,,,) = pool.getUserAccountData(carol);
        assertEq(carolCollateral, 6_000e18, "received aTokens count as collateral");
    }

    function test_ATokenTransferBlockedIfItBreaksHealthFactor() public {
        _setupLiquidity();
        vm.prank(alice);
        pool.borrow(address(usdc), 15_000e6, alice);

        // Moving collateral away while indebted must respect HF >= 1.
        vm.prank(alice);
        vm.expectRevert(bytes("Pool: HF < 1"));
        aWeth.transfer(makeAddr("carol"), 5 ether);
    }

    // ------------------------------ Collateral toggle ------------------------------ //

    function test_SetUserUseReserveAsCollateral() public {
        _setupLiquidity();

        // Turning collateral off with no debt is fine.
        vm.prank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), false);
        (uint256 collateral,,,,,) = pool.getUserAccountData(alice);
        assertEq(collateral, 0);

        // Can't turn it off if debt depends on it.
        vm.startPrank(alice);
        pool.setUserUseReserveAsCollateral(address(weth), true);
        pool.borrow(address(usdc), 10_000e6, alice);
        vm.expectRevert(bytes("Pool: HF < 1"));
        pool.setUserUseReserveAsCollateral(address(weth), false);
        vm.stopPrank();
    }

    // ------------------------------ Config validation ------------------------------ //

    function test_InitReserveRejectsBadConfig() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        DataTypes.ReserveConfig memory cfg = DataTypes.ReserveConfig({
            ltv: 9000,
            liquidationThreshold: 8000, // ltv > threshold: invalid
            liquidationBonus: 10500,
            reserveFactor: 1000,
            supplyCap: 0,
            borrowCap: 0,
            decimals: 18,
            isActive: true,
            isFrozen: false,
            borrowingEnabled: true,
            usableAsCollateral: true
        });
        vm.expectRevert(bytes("Pool: ltv > threshold"));
        pool.initReserve(address(dai), cfg, address(strategy), "DAI");

        cfg.ltv = 7000;
        cfg.liquidationThreshold = 9900;
        cfg.liquidationBonus = 10_500; // 99% * 105% > 100%: guaranteed bad debt
        vm.expectRevert(bytes("Pool: unsafe threshold/bonus"));
        pool.initReserve(address(dai), cfg, address(strategy), "DAI");
    }

    function test_OnlyAdminCanInitReserve() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        DataTypes.ReserveConfig memory cfg = pool.getReserveData(address(weth)).config;

        vm.prank(alice);
        vm.expectRevert(bytes("Pool: not admin"));
        pool.initReserve(address(dai), cfg, address(strategy), "DAI");
    }
}
