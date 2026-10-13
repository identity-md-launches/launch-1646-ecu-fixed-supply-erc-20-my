// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @title CommunityVesting -- the 5 % community slice (ECONOMY.md §9, §11.7)
/// @notice OpenZeppelin `VestingWallet` with the schedule fixed in code: 12 months linear
///         from the start timestamp, no cliff.
///
/// @dev The beneficiary is the wallet's owner and may hand the slice to another address
///      with `transferOwnership`, but may never renounce it: a renounced VestingWallet
///      pays `address(0)` and every `release` reverts, which would strand whatever is
///      still vesting (AUDIT.md finding 8). In production the beneficiary is a Safe.
contract CommunityVesting is VestingWallet {
    /// @notice One year, linear.
    uint64 public constant DURATION = 365 days;

    error RenounceDisabled();

    /// @param beneficiary The owner that may release vested tokens. A Safe in production.
    /// @param startTimestamp When the 12-month schedule begins.
    constructor(address beneficiary, uint64 startTimestamp) VestingWallet(beneficiary, startTimestamp, DURATION) {}

    /// @notice Disabled: a vesting wallet without an owner can never pay out.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
