// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Distributor} from "../src/Distributor.sol";

/// @notice The Sepolia dry run: one creation, `new Distributor(...)`, whose constructor
///         deploys the token, the vault and both vesting wallets and performs the §11.7
///         split in the same transaction.
///
/// @dev There is no ordering, no nonce prediction and no `distribute()` call: the
///      Distributor's constructor resolves the ECU / FarmVault / Distributor cycle by
///      creating all three itself. The script never reads `address(this)` and holds no
///      supply at any point (AUDIT.md finding 1).
///
///      `run()` reads the five destinations from the environment with no default, on
///      purpose: a launch that silently fell back to the deployer would put a slice
///      somewhere nobody chose. On the testnet dry run the owner wallet fills every one of
///      them. `deploy()` takes the configuration as an argument so the tests drive the
///      exact creation that gets broadcast, without touching the environment.
///
///      On mainnet the token is created by IMD's custom_token launch, and the root
///      contract is `TokenDistributor` with the launch's token and expected remainder; that
///      is a later launch and is not scripted here.
contract Distribute is Script {
    /// @notice Initial cap on ECU leaving the vault in one 24-hour window: roughly 7.5x
    ///         the §3.3 Exchange budget at launch, and a week of it stays under gate 6.
    uint256 public constant INITIAL_MAX_OUTFLOW_PER_WINDOW = 250_000e18;
    /// @notice Initial cap on a single voucher.
    uint256 public constant INITIAL_MAX_VOUCHER_AMOUNT = 50_000e18;

    struct Destinations {
        address operator;
        address guardian;
        address teamBeneficiary;
        address communityBeneficiary;
        address listings;
    }

    function run() external returns (Distributor distributor) {
        Destinations memory to = Destinations({
            operator: vm.envAddress("VAULT_OPERATOR"),
            guardian: vm.envAddress("VAULT_GUARDIAN"),
            teamBeneficiary: vm.envAddress("TEAM_BENEFICIARY"),
            communityBeneficiary: vm.envAddress("COMMUNITY_BENEFICIARY"),
            listings: vm.envAddress("LISTINGS_MULTISIG")
        });

        distributor = deploy(to);
        _report(distributor);
    }

    /// @dev The whole deployment: one broadcast creation. Public so the tests exercise the
    ///      real thing rather than a reimplementation that could drift from it.
    function deploy(Destinations memory to) public returns (Distributor distributor) {
        vm.startBroadcast();
        distributor = new Distributor(
            to.operator,
            to.guardian,
            to.teamBeneficiary,
            to.communityBeneficiary,
            to.listings,
            INITIAL_MAX_OUTFLOW_PER_WINDOW,
            INITIAL_MAX_VOUCHER_AMOUNT
        );
        vm.stopBroadcast();
    }

    function _report(Distributor d) internal view {
        console.log("Distributor        ", address(d));
        console.log("ECU                ", address(d.token()));
        console.log("FarmVault          ", address(d.vault()));
        console.log("Team vesting       ", address(d.teamVesting()));
        console.log("Community vesting  ", address(d.communityVesting()));
        console.log("Listings           ", d.listings());
    }
}
