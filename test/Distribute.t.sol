// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Distribute} from "../script/Distribute.s.sol";
import {ECU} from "../src/ECU.sol";
import {FarmVault} from "../src/FarmVault.sol";
import {Distributor} from "../src/Distributor.sol";

/// @notice Drives the real launch script through `run()` -- under broadcast, exactly as
///         `forge script --broadcast` would -- and checks the result against §11.7.
///
/// @dev AUDIT.md finding 1: the old script minted to `address(this)` and could not be
///      broadcast. The test below calls `run()`, so the sender of every creation is the
///      broadcaster and the script's own address holds nothing at any point.
contract DistributeTest is Test {
    Distribute internal script;
    Distribute.Deployment internal d;

    uint256 internal constant TOTAL = 100_000_000e18;

    address internal community = address(0x22);
    address internal team = address(0x33);
    address internal listings = address(0x44);
    address internal operator = address(0x55);
    address internal guardian = address(0x66);

    uint64 internal start;

    function setUp() public {
        vm.setEnv("COMMUNITY_BENEFICIARY", vm.toString(community));
        vm.setEnv("TEAM_BENEFICIARY", vm.toString(team));
        vm.setEnv("LISTINGS_MULTISIG", vm.toString(listings));
        vm.setEnv("VAULT_OPERATOR", vm.toString(operator));
        vm.setEnv("VAULT_GUARDIAN", vm.toString(guardian));

        vm.warp(1_800_000_000);
        start = uint64(block.timestamp);
        script = new Distribute();
        d = script.run();
    }

    // -- broadcast --------------------------------------------------------

    function test_runCompletesUnderBroadcastAndTheScriptHoldsNothing() public view {
        assertEq(d.ecu.balanceOf(address(script)), 0);
        assertEq(d.ecu.balanceOf(address(this)), 0);
        // Nothing stayed with the broadcaster either: the supply went contract to contract.
        assertEq(d.ecu.balanceOf(DEFAULT_SENDER), 0);
        assertTrue(d.distributor.distributed());
    }

    function test_theTokenMintedToTheDistributorNotToAnEoa() public {
        // Replay the deployment without broadcast -- the creations then come from the
        // script contract itself -- and stop before distribute() to see where the mint went.
        Distribute.Destinations memory to = _destinations();
        Distribute.Deployment memory again = script.deployAll(to, start, address(script));

        assertEq(again.ecu.balanceOf(address(again.distributor)), TOTAL);
        assertEq(again.ecu.balanceOf(address(script)), 0);
        assertEq(again.ecu.balanceOf(DEFAULT_SENDER), 0);
        assertEq(address(again.vault.ecu()), address(again.ecu));
        assertFalse(again.distributor.distributed());
    }

    // -- the table --------------------------------------------------------

    function test_theVaultHoldsTheGameSideHalf() public view {
        assertEq(d.ecu.balanceOf(address(d.vault)), (TOTAL * 50) / 75);
    }

    function test_teamVestingHoldsItsShare() public view {
        assertEq(d.ecu.balanceOf(address(d.teamVesting)), (TOTAL * 15) / 75);
    }

    function test_communityVestingHoldsItsShare() public view {
        assertEq(d.ecu.balanceOf(address(d.communityVesting)), (TOTAL * 5) / 75);
    }

    function test_listingsGetsTheRemainder() public view {
        uint256 others = (TOTAL * 50) / 75 + (TOTAL * 15) / 75 + (TOTAL * 5) / 75;
        assertEq(d.ecu.balanceOf(listings), TOTAL - others);
    }

    /// @dev The invariant the entire off-chain ledger rests on.
    function test_everythingIsDistributedAndNothingIsLeft() public view {
        uint256 accounted = d.ecu.balanceOf(address(d.vault)) + d.ecu.balanceOf(address(d.teamVesting))
            + d.ecu.balanceOf(address(d.communityVesting)) + d.ecu.balanceOf(listings);

        assertEq(accounted, TOTAL);
        assertEq(d.ecu.totalSupply(), TOTAL);
        assertEq(d.ecu.balanceOf(address(d.distributor)), 0);
    }

    function test_theDistributorTargetsWhatTheScriptDeployed() public view {
        assertEq(d.distributor.vault(), address(d.vault));
        assertEq(d.distributor.teamVesting(), address(d.teamVesting));
        assertEq(d.distributor.communityVesting(), address(d.communityVesting));
        assertEq(d.distributor.listings(), listings);
    }

    function test_distributeCannotRunTwice() public {
        vm.expectRevert(Distributor.AlreadyDistributed.selector);
        d.distributor.distribute();
    }

    // -- vesting ----------------------------------------------------------

    function test_theTeamScheduleRunsThreeYearsWithAOneYearCliff() public view {
        assertEq(d.teamVesting.owner(), team);
        assertEq(d.teamVesting.start(), start);
        assertEq(d.teamVesting.duration(), 3 * 365 days);
        assertEq(d.teamVesting.cliff(), start + 365 days);
    }

    function test_theCommunityScheduleRunsOneYear() public view {
        assertEq(d.communityVesting.owner(), community);
        assertEq(d.communityVesting.start(), start);
        assertEq(d.communityVesting.duration(), 365 days);
    }

    function test_nothingHasVestedAtLaunch() public view {
        assertEq(d.teamVesting.releasable(address(d.ecu)), 0);
        assertEq(d.communityVesting.releasable(address(d.ecu)), 0);
    }

    /// @dev AUDIT.md finding 6: day one used to release ~54,800 ECU. Now the team slice
    ///      releases nothing and the community slice one 365th of 5 %.
    function test_dayOneReleasesNothingForTheTeamAndOneDayForTheCommunity() public {
        vm.warp(start + 1 days);
        assertEq(d.teamVesting.releasable(address(d.ecu)), 0);
        assertEq(d.communityVesting.releasable(address(d.ecu)), ((TOTAL * 5) / 75) / 365);
    }

    function test_theTeamSliceUnlocksAThirdAtTheCliff() public {
        vm.warp(start + 365 days - 1);
        assertEq(d.teamVesting.releasable(address(d.ecu)), 0);

        vm.warp(start + 365 days);
        assertEq(d.teamVesting.releasable(address(d.ecu)), ((TOTAL * 15) / 75) / 3);
    }

    function test_theTeamSliceIsHalfwayAtEighteenMonths() public {
        vm.warp(start + (3 * 365 days) / 2);
        assertApproxEqRel(d.teamVesting.releasable(address(d.ecu)), 10_000_000e18, 1e12);
    }

    function test_vestingPaysTheBeneficiaryAtTheEnd() public {
        vm.warp(start + 3 * 365 days);
        d.teamVesting.release(address(d.ecu));
        assertEq(d.ecu.balanceOf(team), (TOTAL * 15) / 75);
        assertEq(d.ecu.balanceOf(address(d.teamVesting)), 0);

        d.communityVesting.release(address(d.ecu));
        assertEq(d.ecu.balanceOf(community), (TOTAL * 5) / 75);
    }

    // -- the vault --------------------------------------------------------

    function test_theVaultIsWiredToTheTokenItsKeysAndItsCaps() public view {
        assertEq(address(d.vault.ecu()), address(d.ecu));
        assertEq(d.vault.operator(), operator);
        assertEq(d.vault.guardian(), guardian);
        assertFalse(d.vault.withdrawalsPaused());
        assertEq(d.vault.maxOutflowPerWindow(), script.INITIAL_MAX_OUTFLOW_PER_WINDOW());
        assertEq(d.vault.maxVoucherAmount(), script.INITIAL_MAX_VOUCHER_AMOUNT());
    }

    /// @dev Nobody can mint more, so the launch split is the whole and permanent story.
    function test_theTokenHasNoOwnerAfterDistribution() public view {
        (bool ok,) = address(d.ecu).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function _destinations() internal view returns (Distribute.Destinations memory) {
        return Distribute.Destinations({
            communityBeneficiary: community,
            teamBeneficiary: team,
            listings: listings,
            operator: operator,
            guardian: guardian
        });
    }
}
