// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DistributorBase} from "./DistributorBase.sol";

/// @title TokenDistributor -- the launch root for an existing token (deferred mode)
/// @notice The second mode of the Distributor, for the future IMD custom_token launch: the
///         launch creates the token, places the pool (15 %) and swarm (10 %) slices itself
///         and sends the remaining 75 % here as `remainderTo`. The constructor skips token
///         creation, deploys the FarmVault against the given token and the two vesting
///         wallets, and emits `Launched`. The split then waits for the permissionless
///         one-shot `distribute()`, which runs only once this contract holds at least
///         `expectedBalance`.
///
/// @dev The constructor never calls the token, so it deploys before the token has code --
///      the launch checks constructors on an empty chain, and on a custom_token launch the
///      token may be created after this contract. `expectedBalance` must be the amount the
///      launch will deliver (75 % of the token's supply), and nothing less: a value above
///      what arrives leaves `distribute()` refusing forever, a value below lets a partial
///      delivery consume the one shot.
contract TokenDistributor is DistributorBase {
    /// @param token The token whose remainder this contract will receive. Must be non-zero.
    /// @param expectedBalance The least that must be held before `distribute()` runs.
    /// @param operator The vault's voucher signer. An EOA hot key.
    /// @param guardian The vault's guardian. A Safe in production.
    /// @param teamBeneficiary Owner of the team vesting wallet. A Safe in production.
    /// @param communityBeneficiary Owner of the community vesting wallet. A Safe in production.
    /// @param listings Receives the listings float plus rounding dust. A multisig in production.
    /// @param maxOutflowPerWindow The vault's initial 24-hour outflow cap, in token units.
    /// @param maxVoucherAmount The vault's initial per-voucher cap, in token units.
    constructor(
        address token,
        uint256 expectedBalance,
        address operator,
        address guardian,
        address teamBeneficiary,
        address communityBeneficiary,
        address listings,
        uint256 maxOutflowPerWindow,
        uint256 maxVoucherAmount
    )
        DistributorBase(
            _nonZero(token),
            expectedBalance,
            operator,
            guardian,
            teamBeneficiary,
            communityBeneficiary,
            listings,
            maxOutflowPerWindow,
            maxVoucherAmount
        )
    {}

    /// @dev A zero token would silently select token-creating mode; refuse it here.
    function _nonZero(address token) private pure returns (address) {
        if (token == address(0)) revert ZeroAddress();
        return token;
    }
}
