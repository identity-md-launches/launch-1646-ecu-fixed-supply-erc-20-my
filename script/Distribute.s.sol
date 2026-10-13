// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ECU} from "../src/ECU.sol";
import {FarmVault} from "../src/FarmVault.sol";
import {Distributor} from "../src/Distributor.sol";
import {TeamVesting} from "../src/TeamVesting.sol";
import {CommunityVesting} from "../src/CommunityVesting.sol";

/// @notice The Sepolia dry run: deploys the token, the vault, both vesting wallets and the
///         Distributor, then calls `distribute()` so the §11.7 split is visible on chain.
///
/// @dev The split itself lives in `Distributor`, not here: a script is an ephemeral
///      contract, and the supply must never sit at an address that exists only in forge's
///      simulation (AUDIT.md finding 1). This script therefore never reads `address(this)`.
///      Everything it deploys comes from the broadcaster, and the only address it has to
///      know ahead of time -- the token's, which the vault needs before the token exists --
///      is derived from the broadcaster's nonce and asserted after the fact.
///
///      Every destination is read from the environment with no default, on purpose: a
///      launch that silently fell back to the deployer would put a slice somewhere nobody
///      chose. On the testnet dry run the owner wallet fills every one of them.
///
///      On mainnet the token is created by IMD's custom_token launch (15 % pool, 10 %
///      swarm, 75 % to the Distributor as `remainderTo`), so only the vault, the vesting
///      wallets and the Distributor are deployed there and the token step here is skipped.
contract Distribute is Script {
    /// @notice Initial cap on ECU leaving the vault in one 24-hour window: roughly 7.5x
    ///         the §3.3 Exchange budget at launch, and a week of it stays under gate 6.
    uint256 public constant INITIAL_MAX_OUTFLOW_PER_WINDOW = 250_000e18;
    /// @notice Initial cap on a single voucher.
    uint256 public constant INITIAL_MAX_VOUCHER_AMOUNT = 50_000e18;

    struct Destinations {
        address communityBeneficiary;
        address teamBeneficiary;
        address listings;
        address operator;
        address guardian;
    }

    struct Deployment {
        ECU ecu;
        FarmVault vault;
        TeamVesting teamVesting;
        CommunityVesting communityVesting;
        Distributor distributor;
    }

    function run() external returns (Deployment memory deployment) {
        Destinations memory to = Destinations({
            communityBeneficiary: vm.envAddress("COMMUNITY_BENEFICIARY"),
            teamBeneficiary: vm.envAddress("TEAM_BENEFICIARY"),
            listings: vm.envAddress("LISTINGS_MULTISIG"),
            operator: vm.envAddress("VAULT_OPERATOR"),
            guardian: vm.envAddress("VAULT_GUARDIAN")
        });

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        deployment = deployAll(to, uint64(block.timestamp), deployer);
        deployment.distributor.distribute();
        vm.stopBroadcast();

        _report(deployment, to);
    }

    /// @dev Split out, and public, so the tests exercise the real deployment rather than a
    ///      reimplementation of it that could drift from what actually gets broadcast.
    ///      `deployer` is whoever the five creations below come from; its nonce fixes the
    ///      token's address before the token exists, which is what lets the vault take it
    ///      as an immutable and the token mint to the Distributor that targets the vault.
    function deployAll(Destinations memory to, uint64 startAt, address deployer)
        public
        returns (Deployment memory deployment)
    {
        uint64 nonce = vm.getNonce(deployer);
        address predictedEcu = vm.computeCreateAddress(deployer, nonce + 4);

        deployment.teamVesting = new TeamVesting(to.teamBeneficiary, startAt); // nonce
        deployment.communityVesting = new CommunityVesting(to.communityBeneficiary, startAt); // nonce + 1
        deployment.vault = new FarmVault( // nonce + 2
            ECU(predictedEcu),
            to.operator,
            to.guardian,
            INITIAL_MAX_OUTFLOW_PER_WINDOW,
            INITIAL_MAX_VOUCHER_AMOUNT
        );
        deployment.distributor = new Distributor( // nonce + 3
            address(deployment.vault),
            address(deployment.teamVesting),
            address(deployment.communityVesting),
            to.listings
        );
        deployment.ecu = new ECU(address(deployment.distributor)); // nonce + 4

        require(address(deployment.ecu) == predictedEcu, "token address prediction failed");
        require(address(deployment.vault.ecu()) == address(deployment.ecu), "vault not wired to token");
    }

    function _report(Deployment memory d, Destinations memory to) internal pure {
        console.log("ECU                ", address(d.ecu));
        console.log("FarmVault          ", address(d.vault));
        console.log("Distributor        ", address(d.distributor));
        console.log("Team vesting       ", address(d.teamVesting));
        console.log("Community vesting  ", address(d.communityVesting));
        console.log("Listings           ", to.listings);
    }
}
