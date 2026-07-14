// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFlashLoanReceiver {
    /**
     * @notice Called by the pool after transferring the flash-loaned amount.
     *         By the end of this call the receiver must have approved the pool
     *         to pull `amount + premium` of `asset`.
     * @return true on success; anything else reverts the whole flash loan.
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
