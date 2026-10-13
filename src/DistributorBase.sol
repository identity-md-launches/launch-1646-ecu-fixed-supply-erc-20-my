// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECU} from "./ECU.sol";
import {FarmVault} from "./FarmVault.sol";
import {TeamVesting} from "./TeamVesting.sol";
import {CommunityVesting} from "./CommunityVesting.sol";

/// @title DistributorBase -- the launch root that creates the system and splits the supply
/// @notice One constructor deploys the FarmVault, the team vesting wallet and the community
///         vesting wallet, and -- in token-creating mode -- the ECU token itself, then
///         splits what it holds per ECONOMY.md §9 / §11.7: 50/75 to the vault, 15/75 to
///         team vesting, 5/75 to community vesting and the remainder to listings.
///
/// @dev **Why a root contract.** `ECU(distributor)` mints its supply to the Distributor,
///      `FarmVault(ecu, …)` fixes the token as an immutable, and the Distributor fixes the
///      vault. Deployed as separate transactions those three form a cycle that only a
///      nonce prediction can resolve, and a launch manifest that deploys from bytecode has
///      no nonce to predict. Creating everything from inside one constructor removes the
///      cycle: `address(this)` is known before the token exists, the token is known before
///      the vault exists, and all of it is one atomic transaction that either leaves the
///      whole system wired and funded or leaves nothing.
///
///      **Two modes, chosen by the `token_` argument of this base constructor.**
///      - `token_ == address(0)` (the `Distributor` contract): create the ECU token so the
///        entire supply is minted here, then split it in the same constructor. Nothing
///        remains to do after deployment and this contract ends with a zero balance.
///      - `token_ != address(0)` (the `TokenDistributor` contract): the token already
///        exists, or will be created by the launch that sends its remainder here. Only the
///        vault and the vesting wallets are created, no call is made to the token, and the
///        split waits for the permissionless one-shot `distribute()`, which refuses to run
///        until at least `expectedBalance` has arrived.
///
///      **Shares are fractions of what arrives, not of the total supply.** On a
///      custom_token launch the pool and swarm slices never pass through here, so the
///      split is written over the 75 that does; on the dry run the whole supply arrives and
///      the same fractions apply. Integer-division dust goes to listings, so nothing is
///      stranded.
///
///      **No owner, no privileged caller.** Every address this contract will ever use is an
///      immutable fixed at construction, and the only state is the `distributed` flag.
abstract contract DistributorBase {
    using SafeERC20 for IERC20;

    uint256 public constant VAULT_SHARE = 50;
    uint256 public constant TEAM_SHARE = 15;
    uint256 public constant COMMUNITY_SHARE = 5;
    uint256 public constant LISTINGS_SHARE = 5;
    /// @notice The denominator: the share of supply that reaches this contract on mainnet.
    uint256 public constant TOTAL_SHARE = 75;

    /// @notice The token being distributed: created here, or the one the launch created.
    IERC20 public immutable token;
    /// @notice The FarmVault created here, custodying the game-side 50/75.
    FarmVault public immutable vault;
    /// @notice The team's vesting wallet created here: 36 months, 12-month cliff.
    TeamVesting public immutable teamVesting;
    /// @notice The community's vesting wallet created here: 12 months linear.
    CommunityVesting public immutable communityVesting;
    /// @notice The exchange-listing float, held rather than provided as liquidity.
    address public immutable listings;
    /// @notice The least this contract must hold before `distribute()` will run. Zero in
    ///         token-creating mode, where the split already happened in the constructor.
    uint256 public immutable expectedBalance;

    /// @notice True once the split has run: from the constructor in token-creating mode,
    ///         from `distribute()` otherwise.
    bool public distributed;

    /// @notice The one event that names everything the constructor created or fixed.
    event Launched(
        address indexed token, address indexed vault, address teamVesting, address communityVesting, address listings
    );

    event Distributed(
        address indexed token,
        uint256 received,
        uint256 toVault,
        uint256 toTeamVesting,
        uint256 toCommunityVesting,
        uint256 toListings
    );

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyDistributed();
    error InsufficientBalance(uint256 held, uint256 expected);

    /// @param token_ `address(0)` to create the ECU token here and split it at once;
    ///        otherwise the token whose remainder this contract will receive.
    /// @param expectedBalance_ In token mode, the least that must arrive before the split
    ///        runs. Ignored in token-creating mode (the whole supply is here by definition).
    /// @param operator The vault's voucher signer. An EOA hot key.
    /// @param guardian The vault's guardian. A Safe in production.
    /// @param teamBeneficiary Owner of the team vesting wallet. A Safe in production.
    /// @param communityBeneficiary Owner of the community vesting wallet. A Safe in production.
    /// @param listings_ Receives the listings float plus rounding dust. A multisig in production.
    /// @param maxOutflowPerWindow The vault's initial 24-hour outflow cap.
    /// @param maxVoucherAmount The vault's initial per-voucher cap.
    constructor(
        address token_,
        uint256 expectedBalance_,
        address operator,
        address guardian,
        address teamBeneficiary,
        address communityBeneficiary,
        address listings_,
        uint256 maxOutflowPerWindow,
        uint256 maxVoucherAmount
    ) {
        // The vault and the vesting wallets refuse their own zero addresses and zero caps;
        // listings is the one target only this contract checks.
        if (listings_ == address(0)) revert ZeroAddress();

        bool createToken = token_ == address(0);
        IERC20 token__ = createToken ? IERC20(address(new ECU(address(this)))) : IERC20(token_);
        FarmVault vault_ = new FarmVault(token__, operator, guardian, maxOutflowPerWindow, maxVoucherAmount);
        uint64 start = uint64(block.timestamp);
        TeamVesting teamVesting_ = new TeamVesting(teamBeneficiary, start);
        CommunityVesting communityVesting_ = new CommunityVesting(communityBeneficiary, start);

        token = token__;
        vault = vault_;
        teamVesting = teamVesting_;
        communityVesting = communityVesting_;
        listings = listings_;

        emit Launched(address(token__), address(vault_), address(teamVesting_), address(communityVesting_), listings_);

        if (createToken) {
            // The whole supply was just minted here. Split it now, atomically with the
            // creations above, so the launch transaction leaves nothing to call later.
            expectedBalance = 0;
            distributed = true;
            uint256 minted = token__.balanceOf(address(this));
            _split(token__, minted, address(vault_), address(teamVesting_), address(communityVesting_));
        } else {
            // No call to the token here: it may not exist yet when this constructor runs,
            // and the launch checks constructors on an empty chain.
            if (expectedBalance_ == 0) revert ZeroAmount();
            expectedBalance = expectedBalance_;
        }
    }

    /// @notice Split everything this contract holds, once. Anyone may call it.
    /// @dev Only meaningful in token mode. Refuses to run until at least `expectedBalance`
    ///      has arrived, so a call before the launch has delivered the remainder cannot
    ///      consume the one shot with a partial amount.
    function distribute() external {
        if (distributed) revert AlreadyDistributed();
        uint256 held = token.balanceOf(address(this));
        if (held < expectedBalance) revert InsufficientBalance(held, expectedBalance);
        distributed = true;
        _split(token, held, address(vault), address(teamVesting), address(communityVesting));
    }

    function _split(IERC20 token_, uint256 received, address vault_, address team_, address community_) private {
        uint256 toVault = (received * VAULT_SHARE) / TOTAL_SHARE;
        uint256 toTeam = (received * TEAM_SHARE) / TOTAL_SHARE;
        uint256 toCommunity = (received * COMMUNITY_SHARE) / TOTAL_SHARE;
        // The remainder, not a fourth division: rounding dust lands here instead of
        // staying behind as supply nobody accounted for.
        uint256 toListings = received - toVault - toTeam - toCommunity;

        emit Distributed(address(token_), received, toVault, toTeam, toCommunity, toListings);

        token_.safeTransfer(vault_, toVault);
        token_.safeTransfer(team_, toTeam);
        token_.safeTransfer(community_, toCommunity);
        token_.safeTransfer(listings, toListings);
    }
}
