// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECU} from "../src/ECU.sol";
import {TeamVesting} from "../src/TeamVesting.sol";
import {CommunityVesting} from "../src/CommunityVesting.sol";

/// @notice The two vesting wallets: schedule fixed in code, ownership transferable but
///         never renounceable (AUDIT.md findings 6 and 8).
contract VestingTest is Test {
    ECU internal ecu;
    TeamVesting internal teamVesting;
    CommunityVesting internal communityVesting;

    address internal team = address(0x33);
    address internal community = address(0x22);
    uint64 internal constant START = 1_800_000_000;

    uint256 internal constant TEAM_SLICE = 15_000_000e18;
    uint256 internal constant COMMUNITY_SLICE = 5_000_000e18;

    function setUp() public {
        ecu = new ECU(address(this));
        teamVesting = new TeamVesting(team, START);
        communityVesting = new CommunityVesting(community, START);
        ecu.transfer(address(teamVesting), TEAM_SLICE);
        ecu.transfer(address(communityVesting), COMMUNITY_SLICE);
        vm.warp(START);
    }

    // -- schedules --------------------------------------------------------

    function test_theSchedulesAreFixedInCode() public view {
        assertEq(teamVesting.start(), START);
        assertEq(teamVesting.duration(), 3 * 365 days);
        assertEq(teamVesting.cliff(), START + 365 days);
        assertEq(teamVesting.end(), START + 3 * 365 days);
        assertEq(communityVesting.start(), START);
        assertEq(communityVesting.duration(), 365 days);
        assertEq(communityVesting.end(), START + 365 days);
    }

    function test_nothingIsReleasableAtLaunch() public view {
        assertEq(teamVesting.releasable(address(ecu)), 0);
        assertEq(communityVesting.releasable(address(ecu)), 0);
    }

    function test_dayOneAmounts() public {
        vm.warp(START + 1 days);
        assertEq(teamVesting.releasable(address(ecu)), 0);
        assertEq(communityVesting.releasable(address(ecu)), COMMUNITY_SLICE / 365);

        vm.prank(address(0xDEAD)); // release is permissionless, pays the owner
        communityVesting.release(address(ecu));
        assertEq(ecu.balanceOf(community), COMMUNITY_SLICE / 365);
        assertEq(ecu.balanceOf(team), 0);
    }

    function test_theTeamCliffReleasesNothingUntilItEnds() public {
        vm.warp(START + 365 days - 1);
        assertEq(teamVesting.releasable(address(ecu)), 0);
        teamVesting.release(address(ecu));
        assertEq(ecu.balanceOf(team), 0);

        vm.warp(START + 365 days);
        assertEq(teamVesting.releasable(address(ecu)), TEAM_SLICE / 3);
        teamVesting.release(address(ecu));
        assertEq(ecu.balanceOf(team), TEAM_SLICE / 3);
    }

    function test_theTeamScheduleIsLinearAfterTheCliff() public {
        vm.warp(START + 2 * 365 days);
        assertEq(teamVesting.releasable(address(ecu)), (TEAM_SLICE * 2) / 3);
        vm.warp(START + 3 * 365 days);
        assertEq(teamVesting.releasable(address(ecu)), TEAM_SLICE);
        vm.warp(START + 10 * 365 days);
        assertEq(teamVesting.releasable(address(ecu)), TEAM_SLICE);
    }

    function test_theCommunityScheduleIsLinearWithNoCliff() public {
        vm.warp(START + 182 days + 12 hours);
        assertEq(communityVesting.releasable(address(ecu)), COMMUNITY_SLICE / 2);
        vm.warp(START + 365 days);
        assertEq(communityVesting.releasable(address(ecu)), COMMUNITY_SLICE);
    }

    function testFuzz_releasedNeverExceedsTheSchedule(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 4 * 365 days);
        vm.warp(START + elapsed);

        uint256 expectedTeam =
            elapsed < 365 days ? 0 : (elapsed >= 3 * 365 days ? TEAM_SLICE : (TEAM_SLICE * elapsed) / (3 * 365 days));
        uint256 expectedCommunity = elapsed >= 365 days ? COMMUNITY_SLICE : (COMMUNITY_SLICE * elapsed) / (365 days);

        teamVesting.release(address(ecu));
        communityVesting.release(address(ecu));
        assertEq(ecu.balanceOf(team), expectedTeam);
        assertEq(ecu.balanceOf(community), expectedCommunity);
    }

    // -- ownership --------------------------------------------------------

    function test_renounceIsDisabledOnBoth() public {
        vm.prank(team);
        vm.expectRevert(TeamVesting.RenounceDisabled.selector);
        teamVesting.renounceOwnership();

        vm.prank(community);
        vm.expectRevert(CommunityVesting.RenounceDisabled.selector);
        communityVesting.renounceOwnership();

        // Not even a stranger gets a different answer: the function is simply gone.
        vm.expectRevert(TeamVesting.RenounceDisabled.selector);
        teamVesting.renounceOwnership();

        assertEq(teamVesting.owner(), team);
        assertEq(communityVesting.owner(), community);
    }

    function test_transferOwnershipStaysForMigratingSafes() public {
        address newSafe = address(0x5AFE);
        vm.prank(team);
        teamVesting.transferOwnership(newSafe);
        assertEq(teamVesting.owner(), newSafe);

        vm.warp(START + 3 * 365 days);
        teamVesting.release(address(ecu));
        assertEq(ecu.balanceOf(newSafe), TEAM_SLICE);
        assertEq(ecu.balanceOf(team), 0);
    }

    function test_onlyTheOwnerTransfers() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        teamVesting.transferOwnership(address(0xBAD));
    }

    function test_transferToZeroIsRefused() public {
        vm.prank(team);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        teamVesting.transferOwnership(address(0));
    }

    function test_constructorsRefuseAZeroBeneficiary() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new TeamVesting(address(0), START);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CommunityVesting(address(0), START);
    }

    /// @dev The factory sends no ETH at deployment; the constructors must not want any.
    function test_constructorsAreNotPayable() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        new TeamVesting{value: 1}(team, START);
        vm.expectRevert();
        new CommunityVesting{value: 1}(community, START);
    }
}
