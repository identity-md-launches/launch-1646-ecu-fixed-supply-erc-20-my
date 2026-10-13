// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECU} from "../src/ECU.sol";
import {FarmVault} from "../src/FarmVault.sol";
import {Distributor} from "../src/Distributor.sol";

/// @notice The split as a contract: fractions of what arrives, run once, dust to listings.
contract DistributorTest is Test {
    ECU internal ecu;
    FarmVault internal vault;
    Distributor internal distributor;

    address internal teamVesting = address(0x7EA1);
    address internal communityVesting = address(0xC0DE);
    address internal listings = address(0x44);
    address internal operator = address(0x55);
    address internal guardian = address(0x66);

    function setUp() public {
        // The token mints to this test, which plays the custom_token launch: it forwards
        // whatever share the scenario needs to the Distributor.
        ecu = new ECU(address(this));
        vault = new FarmVault(ecu, operator, guardian, 250_000e18, 50_000e18);
        distributor = new Distributor(address(vault), teamVesting, communityVesting, listings);
    }

    /// @dev The mainnet case: 75 % of supply arrives as `remainderTo`.
    function test_seventyFivePercentSplitsToTheSpecTable() public {
        ecu.transfer(address(distributor), 75_000_000e18);

        vm.expectEmit(true, false, false, true, address(distributor));
        emit Distributor.Distributed(
            address(ecu), 75_000_000e18, 50_000_000e18, 15_000_000e18, 5_000_000e18, 5_000_000e18
        );
        vm.prank(address(0xA11CE)); // permissionless
        distributor.distribute();

        assertEq(ecu.balanceOf(address(vault)), 50_000_000e18);
        assertEq(ecu.balanceOf(teamVesting), 15_000_000e18);
        assertEq(ecu.balanceOf(communityVesting), 5_000_000e18);
        assertEq(ecu.balanceOf(listings), 5_000_000e18);
        assertEq(ecu.balanceOf(address(distributor)), 0);
        assertTrue(distributor.distributed());
    }

    /// @dev The dry-run case: the whole supply arrives and the same fractions apply.
    function test_theWholeSupplySplitsInTheSameProportions() public {
        ecu.transfer(address(distributor), 100_000_000e18);
        distributor.distribute();

        assertEq(ecu.balanceOf(address(vault)), uint256(100_000_000e18) * 50 / 75);
        assertEq(ecu.balanceOf(teamVesting), uint256(100_000_000e18) * 15 / 75);
        assertEq(ecu.balanceOf(communityVesting), uint256(100_000_000e18) * 5 / 75);
        assertEq(ecu.balanceOf(address(distributor)), 0);
    }

    /// @dev Whatever arrives, the four outputs sum to it exactly and the dust is in listings.
    function testFuzz_theSplitSumsToTheReceivedBalance(uint256 received) public {
        received = bound(received, 1, 100_000_000e18);
        ecu.transfer(address(distributor), received);

        distributor.distribute();

        uint256 toVault = ecu.balanceOf(address(vault));
        uint256 toTeam = ecu.balanceOf(teamVesting);
        uint256 toCommunity = ecu.balanceOf(communityVesting);
        uint256 toListings = ecu.balanceOf(listings);

        assertEq(toVault + toTeam + toCommunity + toListings, received);
        assertEq(ecu.balanceOf(address(distributor)), 0);
        assertEq(toVault, (received * 50) / 75);
        assertEq(toTeam, (received * 15) / 75);
        assertEq(toCommunity, (received * 5) / 75);
        // Listings gets its 5/75 plus at most three units of rounding dust.
        assertGe(toListings, (received * 5) / 75);
        assertLe(toListings, (received * 5) / 75 + 3);
    }

    function test_distributeRunsOnce() public {
        ecu.transfer(address(distributor), 75e18);
        distributor.distribute();

        ecu.transfer(address(distributor), 75e18);
        vm.expectRevert(Distributor.AlreadyDistributed.selector);
        distributor.distribute();
        assertEq(ecu.balanceOf(address(distributor)), 75e18);
    }

    /// @dev An empty call must not burn the one shot: a griefer calling before the token
    ///      arrives would otherwise strand the launch.
    function test_distributeWithNothingDoesNotConsumeTheShot() public {
        vm.expectRevert(Distributor.NothingToDistribute.selector);
        distributor.distribute();
        assertFalse(distributor.distributed());

        ecu.transfer(address(distributor), 75e18);
        distributor.distribute();
        assertEq(ecu.balanceOf(address(vault)), 50e18);
    }

    function test_targetsAreFixedAtConstruction() public view {
        assertEq(distributor.vault(), address(vault));
        assertEq(distributor.teamVesting(), teamVesting);
        assertEq(distributor.communityVesting(), communityVesting);
        assertEq(distributor.listings(), listings);
        assertEq(
            distributor.VAULT_SHARE() + distributor.TEAM_SHARE() + distributor.COMMUNITY_SHARE()
                + distributor.LISTINGS_SHARE(),
            distributor.TOTAL_SHARE()
        );
    }

    function test_refusesAZeroTarget() public {
        vm.expectRevert(Distributor.ZeroAddress.selector);
        new Distributor(address(0), teamVesting, communityVesting, listings);
        vm.expectRevert(Distributor.ZeroAddress.selector);
        new Distributor(address(vault), address(0), communityVesting, listings);
        vm.expectRevert(Distributor.ZeroAddress.selector);
        new Distributor(address(vault), teamVesting, address(0), listings);
        vm.expectRevert(Distributor.ZeroAddress.selector);
        new Distributor(address(vault), teamVesting, communityVesting, address(0));
    }

    /// @dev The constructor makes no external call, so it deploys where the vault has no
    ///      code yet -- the launch rehearsal runs constructors on an empty chain.
    function test_constructsBeforeTheVaultExists() public {
        address futureVault = address(0xFFFF);
        assertEq(futureVault.code.length, 0);
        Distributor early = new Distributor(futureVault, teamVesting, communityVesting, listings);
        assertEq(early.vault(), futureVault);
    }

    function test_hasNoPrivilegedCaller() public view {
        (bool ok,) = address(distributor).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }
}
