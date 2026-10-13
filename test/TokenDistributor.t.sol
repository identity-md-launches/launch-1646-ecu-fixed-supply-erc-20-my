// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECU} from "../src/ECU.sol";
import {FarmVault} from "../src/FarmVault.sol";
import {DistributorBase} from "../src/DistributorBase.sol";
import {TokenDistributor} from "../src/TokenDistributor.sol";

/// @notice The root contract in token mode, for the custom_token launch: the token exists
///         (or will), the constructor creates only the vault and the vesting wallets, and
///         the split waits for a permissionless one-shot `distribute()` that needs at least
///         the expected balance to be here.
contract TokenDistributorTest is Test {
    uint256 internal constant TOTAL = 100_000_000e18;
    /// @dev What the custom_token launch delivers: 75 % of the supply as `remainderTo`.
    uint256 internal constant EXPECTED = 75_000_000e18;
    uint256 internal constant MAX_OUTFLOW = 250_000e18;
    uint256 internal constant MAX_VOUCHER = 50_000e18;

    address internal operator = address(0x55);
    address internal guardian = address(0x66);
    address internal team = address(0x33);
    address internal community = address(0x22);
    address internal listings = address(0x44);

    ECU internal ecu;
    TokenDistributor internal d;

    function setUp() public {
        vm.warp(1_800_000_000);
        // The token mints to this test, which plays the custom_token launch: it forwards
        // whatever share the scenario needs to the distributor.
        ecu = new ECU(address(this));
        d = _deploy(address(ecu), EXPECTED);
    }

    function _deploy(address token, uint256 expected) internal returns (TokenDistributor) {
        return
            new TokenDistributor(
                token, expected, operator, guardian, team, community, listings, MAX_OUTFLOW, MAX_VOUCHER
            );
    }

    // -- construction -----------------------------------------------------

    function test_theConstructorSkipsTokenCreationAndWiresTheVaultToTheGivenToken() public view {
        assertEq(address(d.token()), address(ecu));
        assertEq(address(d.vault().ecu()), address(ecu));
        assertEq(d.vault().operator(), operator);
        assertEq(d.vault().guardian(), guardian);
        assertEq(d.vault().maxOutflowPerWindow(), MAX_OUTFLOW);
        assertEq(d.vault().maxVoucherAmount(), MAX_VOUCHER);
        assertEq(d.teamVesting().owner(), team);
        assertEq(d.teamVesting().start(), vm.getBlockTimestamp());
        assertEq(d.teamVesting().cliff(), vm.getBlockTimestamp() + 365 days);
        assertEq(d.communityVesting().owner(), community);
        assertEq(d.communityVesting().start(), vm.getBlockTimestamp());
        assertEq(d.listings(), listings);
        assertEq(d.expectedBalance(), EXPECTED);
        assertFalse(d.distributed());
        assertEq(ecu.balanceOf(address(d)), 0);
        // Only one ECU exists: the one this test created.
        assertEq(ecu.totalSupply(), TOTAL);
    }

    /// @dev The constructor never calls the token, so it deploys where the token has no
    ///      code yet -- the launch checks constructors on an empty chain, and the
    ///      custom_token launch may create the token after this contract.
    function test_constructsBeforeTheTokenExists() public {
        address futureToken = address(0xFFFF);
        assertEq(futureToken.code.length, 0);
        TokenDistributor early = _deploy(futureToken, EXPECTED);
        assertEq(address(early.token()), futureToken);
        assertEq(address(early.vault().ecu()), futureToken);
        assertFalse(early.distributed());
    }

    function test_theConstructorEmitsLaunchedWithAllFiveAddresses() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        // No token creation, so the vault is this contract's first creation.
        address vault = vm.computeCreateAddress(next, 1);
        address teamVesting = vm.computeCreateAddress(next, 2);
        address communityVesting = vm.computeCreateAddress(next, 3);

        vm.expectEmit(true, true, false, true, next);
        emit DistributorBase.Launched(address(ecu), vault, teamVesting, communityVesting, listings);
        TokenDistributor again = _deploy(address(ecu), EXPECTED);
        assertEq(address(again.vault()), vault);
        assertEq(address(again.teamVesting()), teamVesting);
        assertEq(address(again.communityVesting()), communityVesting);
    }

    function test_refusesAZeroToken() public {
        vm.expectRevert(DistributorBase.ZeroAddress.selector);
        _deploy(address(0), EXPECTED);
    }

    function test_refusesAZeroExpectedBalance() public {
        vm.expectRevert(DistributorBase.ZeroAmount.selector);
        _deploy(address(ecu), 0);
    }

    function test_refusesAZeroListingsAddress() public {
        vm.expectRevert(DistributorBase.ZeroAddress.selector);
        new TokenDistributor(
            address(ecu), EXPECTED, operator, guardian, team, community, address(0), MAX_OUTFLOW, MAX_VOUCHER
        );
    }

    function test_refusesZeroVaultKeysAndCaps() public {
        vm.expectRevert(FarmVault.ZeroAddress.selector);
        new TokenDistributor(
            address(ecu), EXPECTED, address(0), guardian, team, community, listings, MAX_OUTFLOW, MAX_VOUCHER
        );
        vm.expectRevert(FarmVault.ZeroAmount.selector);
        new TokenDistributor(address(ecu), EXPECTED, operator, guardian, team, community, listings, 0, MAX_VOUCHER);
    }

    // -- the deferred split -----------------------------------------------

    /// @dev The mainnet case: 75 % of supply arrives as `remainderTo`.
    function test_seventyFivePercentSplitsToTheSpecTable() public {
        ecu.transfer(address(d), EXPECTED);

        vm.expectEmit(true, false, false, true, address(d));
        emit DistributorBase.Distributed(
            address(ecu), EXPECTED, 50_000_000e18, 15_000_000e18, 5_000_000e18, 5_000_000e18
        );
        vm.prank(address(0xA11CE)); // permissionless
        d.distribute();

        assertEq(ecu.balanceOf(address(d.vault())), 50_000_000e18);
        assertEq(ecu.balanceOf(address(d.teamVesting())), 15_000_000e18);
        assertEq(ecu.balanceOf(address(d.communityVesting())), 5_000_000e18);
        assertEq(ecu.balanceOf(listings), 5_000_000e18);
        assertEq(ecu.balanceOf(address(d)), 0);
        assertTrue(d.distributed());
    }

    function test_refusesToSplitBelowTheExpectedBalanceAndKeepsTheShot() public {
        vm.expectRevert(abi.encodeWithSelector(DistributorBase.InsufficientBalance.selector, 0, EXPECTED));
        d.distribute();
        assertFalse(d.distributed());

        ecu.transfer(address(d), EXPECTED - 1);
        vm.expectRevert(abi.encodeWithSelector(DistributorBase.InsufficientBalance.selector, EXPECTED - 1, EXPECTED));
        d.distribute();
        assertFalse(d.distributed());
        assertEq(ecu.balanceOf(address(d)), EXPECTED - 1);

        // The last unit arrives and the same call now goes through.
        ecu.transfer(address(d), 1);
        d.distribute();
        assertTrue(d.distributed());
        assertEq(ecu.balanceOf(address(d)), 0);
        assertEq(ecu.balanceOf(address(d.vault())), 50_000_000e18);
    }

    /// @dev More than expected is split too: the shares are of the balance, not of the
    ///      expectation, so an over-delivery is never stranded.
    function test_splitsEverythingItHoldsWhenMoreThanExpectedArrives() public {
        ecu.transfer(address(d), TOTAL);
        d.distribute();
        assertEq(ecu.balanceOf(address(d.vault())), (TOTAL * 50) / 75);
        assertEq(ecu.balanceOf(address(d.teamVesting())), (TOTAL * 15) / 75);
        assertEq(ecu.balanceOf(address(d.communityVesting())), (TOTAL * 5) / 75);
        assertEq(ecu.balanceOf(listings), TOTAL - (TOTAL * 50) / 75 - (TOTAL * 15) / 75 - (TOTAL * 5) / 75);
        assertEq(ecu.balanceOf(address(d)), 0);
    }

    function test_distributeRunsOnce() public {
        ecu.transfer(address(d), EXPECTED);
        d.distribute();

        ecu.transfer(address(d), TOTAL - EXPECTED);
        vm.expectRevert(DistributorBase.AlreadyDistributed.selector);
        d.distribute();
        assertEq(ecu.balanceOf(address(d)), TOTAL - EXPECTED);
    }

    /// @dev Whatever arrives at or above the expectation, the four outputs sum to it
    ///      exactly and the dust is in listings.
    function testFuzz_theSplitSumsToTheReceivedBalance(uint256 received) public {
        received = bound(received, EXPECTED, TOTAL);
        ecu.transfer(address(d), received);

        d.distribute();

        uint256 toVault = ecu.balanceOf(address(d.vault()));
        uint256 toTeam = ecu.balanceOf(address(d.teamVesting()));
        uint256 toCommunity = ecu.balanceOf(address(d.communityVesting()));
        uint256 toListings = ecu.balanceOf(listings);

        assertEq(toVault + toTeam + toCommunity + toListings, received);
        assertEq(ecu.balanceOf(address(d)), 0);
        assertEq(toVault, (received * 50) / 75);
        assertEq(toTeam, (received * 15) / 75);
        assertEq(toCommunity, (received * 5) / 75);
        assertGe(toListings, (received * 5) / 75);
        assertLe(toListings, (received * 5) / 75 + 3);
    }

    /// @dev Any shortfall, by any amount, is refused without spending the shot.
    function testFuzz_anyShortfallIsRefused(uint256 held) public {
        held = bound(held, 0, EXPECTED - 1);
        if (held > 0) ecu.transfer(address(d), held);
        vm.expectRevert(abi.encodeWithSelector(DistributorBase.InsufficientBalance.selector, held, EXPECTED));
        d.distribute();
        assertFalse(d.distributed());
    }

    /// @dev The vault created in token mode custodies the launch token like any other.
    function test_theVaultPaysAVoucherOutOfTheDistributedSlice() public {
        (address signer, uint256 key) = makeAddrAndKey("operator");
        TokenDistributor live = new TokenDistributor(
            address(ecu), EXPECTED, signer, guardian, team, community, listings, MAX_OUTFLOW, MAX_VOUCHER
        );
        ecu.transfer(address(live), EXPECTED);
        live.distribute();

        FarmVault vault = live.vault();
        address player = address(0x91A);
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = vault.voucherDigest(player, 1_000e18, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vault.withdraw(player, 1_000e18, 0, expiry, abi.encodePacked(r, s, v));
        assertEq(ecu.balanceOf(player), 1_000e18);
    }

    function test_hasNoPrivilegedCaller() public view {
        (bool ok,) = address(d).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }
}
