// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DistributorBase} from "./DistributorBase.sol";

/// @title Distributor -- the single root contract of the launch (token-creating mode)
/// @notice The one contract the launch manifest lists. Its constructor creates the ECU
///         token (minted entirely to this contract), the FarmVault, the team vesting wallet
///         and the community vesting wallet, then splits the whole supply 50/75 to the
///         vault, 15/75 to team vesting, 5/75 to community vesting and the remainder to
///         listings, and emits `Launched` with all five addresses. It ends the transaction
///         with a zero balance; no `distribute()` call is needed or possible afterwards.
///
/// @dev Seven static constructor arguments, no call to any pre-existing contract, no owner.
///      The created addresses are public immutables (`token`, `vault`, `teamVesting`,
///      `communityVesting`) next to the fixed `listings`. For the mainnet custom_token
///      launch, where the token is created by the launch, use `TokenDistributor` instead.
contract Distributor is DistributorBase {
    /// @param operator The vault's voucher signer. An EOA hot key.
    /// @param guardian The vault's guardian. A Safe in production.
    /// @param teamBeneficiary Owner of the team vesting wallet. A Safe in production.
    /// @param communityBeneficiary Owner of the community vesting wallet. A Safe in production.
    /// @param listings Receives the listings float plus rounding dust. A multisig in production.
    /// @param maxOutflowPerWindow The vault's initial 24-hour outflow cap, in ECU units.
    /// @param maxVoucherAmount The vault's initial per-voucher cap, in ECU units.
    constructor(
        address operator,
        address guardian,
        address teamBeneficiary,
        address communityBeneficiary,
        address listings,
        uint256 maxOutflowPerWindow,
        uint256 maxVoucherAmount
    )
        DistributorBase(
            address(0),
            0,
            operator,
            guardian,
            teamBeneficiary,
            communityBeneficiary,
            listings,
            maxOutflowPerWindow,
            maxVoucherAmount
        )
    {}
}
