// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.sol";
import {MockFlashLoanReceiver, MockFlashLoanThief} from "../src/mocks/MockFlashLoanReceiver.sol";

contract FlashLoanTest is BaseTest {
    MockFlashLoanReceiver receiver;

    function setUp() public override {
        super.setUp();
        receiver = new MockFlashLoanReceiver(address(pool));
        vm.prank(bob);
        pool.deposit(address(usdc), 500_000e6, bob);
    }

    function test_FlashLoanRepaysWithPremium() public {
        uint256 amount = 100_000e6;
        uint256 premium = (amount * pool.FLASHLOAN_PREMIUM_BPS()) / 10_000; // 90 USDC
        usdc.mint(address(receiver), premium); // receiver's "profit" pays the fee

        uint256 vaultBefore = usdc.balanceOf(address(aUsdc));

        pool.flashLoan(address(receiver), address(usdc), amount, "");

        assertEq(receiver.lastAmount(), amount);
        assertEq(receiver.lastPremium(), premium);
        assertEq(
            usdc.balanceOf(address(aUsdc)), vaultBefore + premium, "vault grew by the premium"
        );
    }

    function test_FlashLoanPremiumAccruesToSuppliers() public {
        uint256 amount = 400_000e6; // large loan => visible premium (360 USDC)
        usdc.mint(address(receiver), (amount * 9) / 10_000);

        uint256 bobBefore = aUsdc.balanceOf(bob);
        pool.flashLoan(address(receiver), address(usdc), amount, "");
        uint256 bobAfter = aUsdc.balanceOf(bob);

        // Bob is the only supplier, so ~the entire premium is his.
        assertApproxEqAbs(bobAfter - bobBefore, 360e6, 1e6, "premium credited to supplier");
    }

    function test_FlashLoanRevertsIfNotRepaid() public {
        MockFlashLoanThief thief = new MockFlashLoanThief();
        vm.expectRevert(); // transferFrom fails: no approval, no funds
        pool.flashLoan(address(thief), address(usdc), 100_000e6, "");
    }

    function test_FlashLoanCannotReenterPool() public {
        // The nonReentrant guard makes reentrancy from the callback impossible;
        // a receiver calling pool.deposit inside executeOperation must revert.
        ReentrantFlashReceiver evil = new ReentrantFlashReceiver(address(pool), address(usdc));
        usdc.mint(address(evil), 1_000e6);
        vm.expectRevert(); // inner call reverts with "Pool: reentrancy"
        pool.flashLoan(address(evil), address(usdc), 10_000e6, "");
    }
}

import {IFlashLoanReceiver} from "../src/interfaces/IFlashLoanReceiver.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract ReentrantFlashReceiver is IFlashLoanReceiver {
    LendingPool immutable pool;
    MockERC20 immutable token;

    constructor(address _pool, address _token) {
        pool = LendingPool(_pool);
        token = MockERC20(_token);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address, bytes calldata)
        external
        returns (bool)
    {
        token.approve(address(pool), type(uint256).max);
        pool.deposit(asset, 100e6, address(this)); // must hit the reentrancy guard
        return premium <= amount; // unreachable
    }
}
