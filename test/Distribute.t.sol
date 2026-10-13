// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Distribute} from "../script/Distribute.s.sol";
import {ECU} from "../src/ECU.sol";
import {Distributor} from "../src/Distributor.sol";
import {DistributorBase} from "../src/DistributorBase.sol";

/// @notice Drives the real launch script's `deploy()` -- under broadcast, exactly as
///         `forge script --broadcast` would -- and checks the result against §11.7.
///
/// @dev `run()` reads the environment, which the tests never touch; `deploy()` takes the
///      same configuration as an argument and is what `run()` calls. The deployment is one
///      creation, so the only thing left to check is that the broadcaster and the script
///      hold nothing and that the Distributor did everything (AUDIT.md finding 1).
contract DistributeTest is Test {
    Distribute internal script;
    Distributor internal d;
    ECU internal ecu;

    uint256 internal constant TOTAL = 100_000_000e18;

    address internal operator = address(0x55);
    address internal guardian = address(0x66);
    address internal team = address(0x33);
    address internal community = address(0x22);
    address internal listings = address(0x44);

    uint64 internal start;
    address internal predicted;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = uint64(vm.getBlockTimestamp());
        script = new Distribute();
        predicted = vm.computeCreateAddress(DEFAULT_SENDER, vm.getNonce(DEFAULT_SENDER));
        d = script.deploy(_destinations());
        ecu = ECU(address(d.token()));
    }

    function test_deployCompletesUnderBroadcastAndNobodyOnTheWayHoldsAnything() public view {
        assertEq(ecu.balanceOf(address(script)), 0);
        assertEq(ecu.balanceOf(address(this)), 0);
        // Nothing stayed with the broadcaster either: the supply went contract to contract.
        assertEq(ecu.balanceOf(DEFAULT_SENDER), 0);
        assertEq(ecu.balanceOf(address(d)), 0);
        assertTrue(d.distributed());
    }

    /// @dev Under broadcast the creation comes from the broadcaster, so the Distributor's
    ///      address is the broadcaster's next CREATE address, not the script's.
    function test_theDistributorWasCreatedByTheBroadcaster() public view {
        assertEq(address(d), predicted);
        assertTrue(predicted != vm.computeCreateAddress(address(script), 1));
        assertEq(address(ecu), vm.computeCreateAddress(address(d), 1));
    }

    function test_theSplitIsVisibleOnChain() public view {
        assertEq(ecu.balanceOf(address(d.vault())), (TOTAL * 50) / 75);
        assertEq(ecu.balanceOf(address(d.teamVesting())), (TOTAL * 15) / 75);
        assertEq(ecu.balanceOf(address(d.communityVesting())), (TOTAL * 5) / 75);
        uint256 others = (TOTAL * 50) / 75 + (TOTAL * 15) / 75 + (TOTAL * 5) / 75;
        assertEq(ecu.balanceOf(listings), TOTAL - others);
        assertEq(ecu.totalSupply(), TOTAL);
    }

    function test_theDestinationsAreTheOnesTheScriptWasGiven() public view {
        assertEq(d.vault().operator(), operator);
        assertEq(d.vault().guardian(), guardian);
        assertEq(d.teamVesting().owner(), team);
        assertEq(d.communityVesting().owner(), community);
        assertEq(d.listings(), listings);
    }

    function test_theVaultCarriesTheScriptsInitialCaps() public view {
        assertEq(address(d.vault().ecu()), address(ecu));
        assertEq(d.vault().maxOutflowPerWindow(), script.INITIAL_MAX_OUTFLOW_PER_WINDOW());
        assertEq(d.vault().maxVoucherAmount(), script.INITIAL_MAX_VOUCHER_AMOUNT());
        assertFalse(d.vault().withdrawalsPaused());
    }

    function test_theVestingSchedulesStartAtDeployment() public view {
        assertEq(d.teamVesting().start(), start);
        assertEq(d.teamVesting().duration(), 3 * 365 days);
        assertEq(d.teamVesting().cliff(), start + 365 days);
        assertEq(d.communityVesting().start(), start);
        assertEq(d.communityVesting().duration(), 365 days);
        assertEq(d.teamVesting().releasable(address(ecu)), 0);
        assertEq(d.communityVesting().releasable(address(ecu)), 0);
    }

    /// @dev The dry run's actual configuration: one wallet in every seat. The split is
    ///      then 70/75 to the three contracts and the listings slice back to that wallet.
    function test_theDryRunWithOneWalletInEverySeat() public {
        address owner = address(0x0E0E);
        Distribute.Destinations memory to = Distribute.Destinations({
            operator: owner, guardian: owner, teamBeneficiary: owner, communityBeneficiary: owner, listings: owner
        });
        Distributor dry = script.deploy(to);
        ECU dryEcu = ECU(address(dry.token()));

        assertEq(dry.vault().operator(), owner);
        assertEq(dry.vault().guardian(), owner);
        assertEq(dry.teamVesting().owner(), owner);
        assertEq(dry.communityVesting().owner(), owner);
        assertEq(dry.listings(), owner);
        assertEq(dryEcu.balanceOf(owner), TOTAL - (TOTAL * 50) / 75 - (TOTAL * 15) / 75 - (TOTAL * 5) / 75);
        assertEq(dryEcu.balanceOf(address(dry)), 0);
    }

    function test_deployRefusesAZeroDestination() public {
        Distribute.Destinations memory to = _destinations();
        to.listings = address(0);
        vm.expectRevert(DistributorBase.ZeroAddress.selector);
        script.deploy(to);
    }

    function _destinations() internal view returns (Distribute.Destinations memory) {
        return Distribute.Destinations({
            operator: operator,
            guardian: guardian,
            teamBeneficiary: team,
            communityBeneficiary: community,
            listings: listings
        });
    }
}
