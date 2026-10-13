// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECU} from "../src/ECU.sol";
import {FarmVault} from "../src/FarmVault.sol";
import {Distributor} from "../src/Distributor.sol";
import {DistributorBase} from "../src/DistributorBase.sol";
import {TeamVesting} from "../src/TeamVesting.sol";
import {CommunityVesting} from "../src/CommunityVesting.sol";

/// @notice The root contract in token-creating mode: one constructor creates the token,
///         the vault and both vesting wallets, splits the whole supply and ends empty.
contract DistributorTest is Test {
    uint256 internal constant TOTAL = 100_000_000e18;
    uint256 internal constant MAX_OUTFLOW = 250_000e18;
    uint256 internal constant MAX_VOUCHER = 50_000e18;

    address internal operator = address(0x55);
    address internal guardian = address(0x66);
    address internal team = address(0x33);
    address internal community = address(0x22);
    address internal listings = address(0x44);

    uint64 internal start;
    Distributor internal d;
    ECU internal ecu;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = uint64(vm.getBlockTimestamp());
        d = _deploy();
        ecu = ECU(address(d.token()));
    }

    function _deploy() internal returns (Distributor) {
        return new Distributor(operator, guardian, team, community, listings, MAX_OUTFLOW, MAX_VOUCHER);
    }

    // -- the constructor is the whole launch ------------------------------

    function test_theConstructorCreatesEverythingAndExposesIt() public view {
        assertTrue(address(d.token()).code.length > 0);
        assertTrue(address(d.vault()).code.length > 0);
        assertTrue(address(d.teamVesting()).code.length > 0);
        assertTrue(address(d.communityVesting()).code.length > 0);
        assertEq(d.listings(), listings);
        assertEq(ecu.name(), "e-Farm ECU");
        assertEq(ecu.symbol(), "ECU");
    }

    function test_theWholeSupplyWasMintedToTheDistributorAndSplitAtOnce() public view {
        assertEq(ecu.totalSupply(), TOTAL);
        assertEq(ecu.balanceOf(address(d)), 0);
        assertTrue(d.distributed());
        assertEq(d.expectedBalance(), 0);

        assertEq(ecu.balanceOf(address(d.vault())), (TOTAL * 50) / 75);
        assertEq(ecu.balanceOf(address(d.teamVesting())), (TOTAL * 15) / 75);
        assertEq(ecu.balanceOf(address(d.communityVesting())), (TOTAL * 5) / 75);
        uint256 others = (TOTAL * 50) / 75 + (TOTAL * 15) / 75 + (TOTAL * 5) / 75;
        assertEq(ecu.balanceOf(listings), TOTAL - others);
    }

    /// @dev The invariant the entire off-chain ledger rests on.
    function test_everythingIsDistributedAndNothingIsLeft() public view {
        uint256 accounted = ecu.balanceOf(address(d.vault())) + ecu.balanceOf(address(d.teamVesting()))
            + ecu.balanceOf(address(d.communityVesting())) + ecu.balanceOf(listings);
        assertEq(accounted, TOTAL);
        assertEq(ecu.balanceOf(address(d)), 0);
        assertEq(ecu.balanceOf(address(this)), 0);
    }

    function test_theConstructorEmitsLaunchedWithAllFiveAddressesAndDistributed() public {
        // Every address is a function of the Distributor's own, so all five are known
        // before the creation and can be asserted in the events.
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address token = vm.computeCreateAddress(next, 1);
        address vault = vm.computeCreateAddress(next, 2);
        address teamVesting = vm.computeCreateAddress(next, 3);
        address communityVesting = vm.computeCreateAddress(next, 4);

        vm.expectEmit(true, true, false, true, next);
        emit DistributorBase.Launched(token, vault, teamVesting, communityVesting, listings);
        vm.expectEmit(true, false, false, true, next);
        uint256 toVault = (TOTAL * 50) / 75;
        uint256 toTeam = (TOTAL * 15) / 75;
        uint256 toCommunity = (TOTAL * 5) / 75;
        emit DistributorBase.Distributed(
            token, TOTAL, toVault, toTeam, toCommunity, TOTAL - toVault - toTeam - toCommunity
        );

        Distributor again = _deploy();
        assertEq(address(again), next);
        assertEq(address(again.token()), token);
        assertEq(address(again.vault()), vault);
        assertEq(address(again.teamVesting()), teamVesting);
        assertEq(address(again.communityVesting()), communityVesting);
    }

    function test_distributeHasNothingLeftToDo() public {
        vm.expectRevert(DistributorBase.AlreadyDistributed.selector);
        d.distribute();
    }

    /// @dev Tokens sent here after launch are stuck by design: there is no owner to sweep
    ///      them and the one shot is spent. Documented in README; asserted so it is not
    ///      forgotten.
    function test_distributeStaysClosedEvenIfTokensArriveLater() public {
        vm.prank(listings);
        ecu.transfer(address(d), 1e18);
        vm.expectRevert(DistributorBase.AlreadyDistributed.selector);
        d.distribute();
    }

    // -- the vault --------------------------------------------------------

    function test_theVaultIsWiredToTheTokenItsKeysAndItsCaps() public view {
        FarmVault vault = d.vault();
        assertEq(address(vault.ecu()), address(ecu));
        assertEq(vault.operator(), operator);
        assertEq(vault.guardian(), guardian);
        assertFalse(vault.withdrawalsPaused());
        assertEq(vault.maxOutflowPerWindow(), MAX_OUTFLOW);
        assertEq(vault.maxVoucherAmount(), MAX_VOUCHER);
        assertEq(vault.operatorEpoch(), 0);
    }

    /// @dev The vault works against the token the root created: a voucher pays out of
    ///      the 50/75 slice, bounded by the caps the root passed through.
    function test_theVaultPaysAVoucherSignedByTheOperator() public {
        (address signer, uint256 key) = makeAddrAndKey("operator");
        Distributor live = new Distributor(signer, guardian, team, community, listings, MAX_OUTFLOW, MAX_VOUCHER);
        FarmVault vault = live.vault();
        ECU liveEcu = ECU(address(live.token()));

        address player = address(0x91A);
        uint256 amount = 1_000e18;
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = vault.voucherDigest(player, amount, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);

        vault.withdraw(player, amount, 0, expiry, abi.encodePacked(r, s, v));
        assertEq(liveEcu.balanceOf(player), amount);
        assertEq(liveEcu.balanceOf(address(vault)), (TOTAL * 50) / 75 - amount);
    }

    // -- vesting ----------------------------------------------------------

    function test_theTeamScheduleRunsThreeYearsWithAOneYearCliffFromDeployment() public view {
        TeamVesting tv = d.teamVesting();
        assertEq(tv.owner(), team);
        assertEq(tv.start(), start);
        assertEq(tv.duration(), 3 * 365 days);
        assertEq(tv.cliff(), start + 365 days);
    }

    function test_theCommunityScheduleRunsOneYearFromDeployment() public view {
        CommunityVesting cv = d.communityVesting();
        assertEq(cv.owner(), community);
        assertEq(cv.start(), start);
        assertEq(cv.duration(), 365 days);
    }

    function test_nothingHasVestedAtLaunch() public view {
        assertEq(d.teamVesting().releasable(address(ecu)), 0);
        assertEq(d.communityVesting().releasable(address(ecu)), 0);
    }

    function test_theTeamSliceUnlocksAThirdAtTheCliff() public {
        vm.warp(start + 365 days - 1);
        assertEq(d.teamVesting().releasable(address(ecu)), 0);
        vm.warp(start + 365 days);
        assertEq(d.teamVesting().releasable(address(ecu)), ((TOTAL * 15) / 75) / 3);
    }

    function test_vestingPaysTheBeneficiaryAtTheEnd() public {
        vm.warp(start + 3 * 365 days);
        d.teamVesting().release(address(ecu));
        assertEq(ecu.balanceOf(team), (TOTAL * 15) / 75);
        d.communityVesting().release(address(ecu));
        assertEq(ecu.balanceOf(community), (TOTAL * 5) / 75);
    }

    function test_theVestingWalletsCannotBeRenounced() public {
        TeamVesting tv = d.teamVesting();
        CommunityVesting cv = d.communityVesting();
        vm.prank(team);
        vm.expectRevert(TeamVesting.RenounceDisabled.selector);
        tv.renounceOwnership();
        vm.prank(community);
        vm.expectRevert(CommunityVesting.RenounceDisabled.selector);
        cv.renounceOwnership();
    }

    // -- failure paths ----------------------------------------------------

    function test_refusesAZeroListingsAddress() public {
        vm.expectRevert(DistributorBase.ZeroAddress.selector);
        new Distributor(operator, guardian, team, community, address(0), MAX_OUTFLOW, MAX_VOUCHER);
    }

    function test_refusesAZeroOperatorOrGuardian() public {
        vm.expectRevert(FarmVault.ZeroAddress.selector);
        new Distributor(address(0), guardian, team, community, listings, MAX_OUTFLOW, MAX_VOUCHER);
        vm.expectRevert(FarmVault.ZeroAddress.selector);
        new Distributor(operator, address(0), team, community, listings, MAX_OUTFLOW, MAX_VOUCHER);
    }

    function test_refusesZeroVaultCaps() public {
        vm.expectRevert(FarmVault.ZeroAmount.selector);
        new Distributor(operator, guardian, team, community, listings, 0, MAX_VOUCHER);
        vm.expectRevert(FarmVault.ZeroAmount.selector);
        new Distributor(operator, guardian, team, community, listings, MAX_OUTFLOW, 0);
    }

    function test_refusesAZeroBeneficiary() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Distributor(operator, guardian, address(0), community, listings, MAX_OUTFLOW, MAX_VOUCHER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Distributor(operator, guardian, team, address(0), listings, MAX_OUTFLOW, MAX_VOUCHER);
    }

    /// @dev A failed creation leaves nothing behind: no token, no supply, no vault.
    function test_aRevertedLaunchCreatesNoToken() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address token = vm.computeCreateAddress(next, 1);
        vm.expectRevert(DistributorBase.ZeroAddress.selector);
        new Distributor(operator, guardian, team, community, address(0), MAX_OUTFLOW, MAX_VOUCHER);
        assertEq(next.code.length, 0);
        assertEq(token.code.length, 0);
    }

    function test_hasNoPrivilegedCaller() public view {
        (bool ok,) = address(d).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(ecu).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function test_theSharesSumToTheDenominator() public view {
        assertEq(d.VAULT_SHARE() + d.TEAM_SHARE() + d.COMMUNITY_SHARE() + d.LISTINGS_SHARE(), d.TOTAL_SHARE());
    }

    /// @dev Whatever the five destinations and the caps, the launch is complete and
    ///      conserved, and every destination is the one that was asked for.
    function testFuzz_anyDestinationsGetTheWholeSupply(
        address op,
        address gd,
        address tb,
        address cb,
        address ls,
        uint256 maxOut,
        uint256 maxVoucher
    ) public {
        vm.assume(op != address(0) && gd != address(0) && tb != address(0) && cb != address(0) && ls != address(0));
        maxOut = bound(maxOut, 1, type(uint256).max);
        maxVoucher = bound(maxVoucher, 1, type(uint256).max);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.assume(ls != next && ls != vm.computeCreateAddress(next, 2));

        Distributor f = new Distributor(op, gd, tb, cb, ls, maxOut, maxVoucher);
        ECU t = ECU(address(f.token()));

        assertEq(f.vault().operator(), op);
        assertEq(f.vault().guardian(), gd);
        assertEq(f.teamVesting().owner(), tb);
        assertEq(f.communityVesting().owner(), cb);
        assertEq(f.listings(), ls);
        assertEq(f.vault().maxOutflowPerWindow(), maxOut);
        assertEq(f.vault().maxVoucherAmount(), maxVoucher);

        uint256 accounted = t.balanceOf(address(f.vault())) + t.balanceOf(address(f.teamVesting()))
            + t.balanceOf(address(f.communityVesting())) + t.balanceOf(ls);
        assertEq(accounted, TOTAL);
        assertEq(t.balanceOf(address(f)), 0);
        assertTrue(f.distributed());
    }
}
