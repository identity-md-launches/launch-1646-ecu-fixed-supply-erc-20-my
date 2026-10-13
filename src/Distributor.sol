// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The one thing the Distributor needs from the vault: which token it custodies.
interface IFarmVaultToken {
    function ecu() external view returns (IERC20);
}

/// @title Distributor -- the one-shot launch split of ECONOMY.md §9 / §11.7
/// @notice Holds the launch's share of ECU for exactly one transaction and splits it to
///         four fixed destinations: the vault, team vesting, community vesting and the
///         listings address. No EOA ever holds the supply on the way.
///
/// @dev **Why a contract and not a script.** A forge script runs as an ephemeral contract:
///      under broadcast the transactions come from the signer, but `address(this)` is the
///      script, which exists only in simulation. Minting the supply to it strands the
///      supply (AUDIT.md finding 1). This contract is a real on-chain address the token
///      can mint to -- or, on mainnet, the `remainderTo` target the custom_token launch
///      sends 75 % of supply to after the pool (15 %) and the swarm (10 %) are taken.
///
///      **Shares are fractions of what arrives, not of the total supply.** The pool and
///      swarm slices never pass through here, so the split is expressed over the 75 that
///      does: 50/75 to the vault, 15/75 to team vesting, 5/75 to community vesting, and
///      whatever integer division left over goes to listings with its 5/75, so nothing is
///      stranded. On the Sepolia dry run the token mints its whole supply here and the same
///      fractions apply to 100 M.
///
///      **Targets are fixed at construction and the split runs once.** `distribute` is
///      permissionless because there is nothing to decide: the destinations are immutable,
///      the amount is the balance, and a second call has nothing to do. The constructor
///      makes no external call, so it deploys on an empty chain; the token is read from
///      the vault at distribution time.
contract Distributor {
    using SafeERC20 for IERC20;

    uint256 public constant VAULT_SHARE = 50;
    uint256 public constant TEAM_SHARE = 15;
    uint256 public constant COMMUNITY_SHARE = 5;
    uint256 public constant LISTINGS_SHARE = 5;
    /// @notice The denominator: the share of supply that reaches this contract on mainnet.
    uint256 public constant TOTAL_SHARE = 75;

    /// @notice The FarmVault that custodies the game-side half. Also tells us the token.
    address public immutable vault;
    /// @notice The team's vesting wallet.
    address public immutable teamVesting;
    /// @notice The community's vesting wallet.
    address public immutable communityVesting;
    /// @notice The exchange-listing float, held rather than provided as liquidity.
    address public immutable listings;

    /// @notice True once `distribute` has run.
    bool public distributed;

    event Distributed(
        address indexed token,
        uint256 received,
        uint256 toVault,
        uint256 toTeamVesting,
        uint256 toCommunityVesting,
        uint256 toListings
    );

    error ZeroAddress();
    error AlreadyDistributed();
    error NothingToDistribute();

    /// @param vault_ The FarmVault, which must custody the token this contract receives.
    /// @param teamVesting_ The team vesting wallet.
    /// @param communityVesting_ The community vesting wallet.
    /// @param listings_ The listings address (a multisig in production).
    constructor(address vault_, address teamVesting_, address communityVesting_, address listings_) {
        if (
            vault_ == address(0) || teamVesting_ == address(0) || communityVesting_ == address(0)
                || listings_ == address(0)
        ) revert ZeroAddress();
        vault = vault_;
        teamVesting = teamVesting_;
        communityVesting = communityVesting_;
        listings = listings_;
    }

    /// @notice Split everything this contract holds, once. Anyone may call it.
    function distribute() external {
        if (distributed) revert AlreadyDistributed();
        distributed = true;

        IERC20 token = IFarmVaultToken(vault).ecu();
        uint256 received = token.balanceOf(address(this));
        if (received == 0) revert NothingToDistribute();

        uint256 toVault = (received * VAULT_SHARE) / TOTAL_SHARE;
        uint256 toTeam = (received * TEAM_SHARE) / TOTAL_SHARE;
        uint256 toCommunity = (received * COMMUNITY_SHARE) / TOTAL_SHARE;
        // The remainder, not a fourth division: rounding dust lands here instead of
        // staying behind as supply nobody accounted for.
        uint256 toListings = received - toVault - toTeam - toCommunity;

        emit Distributed(address(token), received, toVault, toTeam, toCommunity, toListings);

        token.safeTransfer(vault, toVault);
        token.safeTransfer(teamVesting, toTeam);
        token.safeTransfer(communityVesting, toCommunity);
        token.safeTransfer(listings, toListings);
    }
}
