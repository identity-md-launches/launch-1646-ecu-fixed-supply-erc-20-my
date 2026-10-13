// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {VestingWalletCliff} from "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/// @title TeamVesting -- the 15 % team slice (ECONOMY.md §9, §11.7)
/// @notice OpenZeppelin `VestingWalletCliff` with the schedule fixed in code: 36 months
///         linear, nothing releasable before a 12-month cliff.
///
/// @dev The beneficiary is the wallet's owner and may hand the slice to another address
///      with `transferOwnership` (a Safe migrating to a new Safe, for instance), but may
///      never renounce it: a renounced VestingWallet pays `address(0)` and every `release`
///      reverts, which would strand whatever is still vesting (AUDIT.md finding 8). In
///      production the beneficiary is a Safe.
contract TeamVesting is VestingWalletCliff {
    /// @notice Three years, the schedule §11.7 gives the team slice.
    uint64 public constant DURATION = 3 * 365 days;
    /// @notice Nothing vests before this much of the schedule has passed.
    uint64 public constant CLIFF = 365 days;

    error RenounceDisabled();

    /// @param beneficiary The owner that may release vested tokens. A Safe in production.
    /// @param startTimestamp When the 36-month schedule begins; the cliff ends 12 months later.
    constructor(address beneficiary, uint64 startTimestamp)
        VestingWallet(beneficiary, startTimestamp, DURATION)
        VestingWalletCliff(CLIFF)
    {}

    /// @notice Disabled: a vesting wallet without an owner can never pay out.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
