// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECU} from "../src/ECU.sol";
import {FarmVault} from "../src/FarmVault.sol";

/// @notice Custody: what gets in, what gets out, who may say so, and how much at once.
contract FarmVaultTest is Test {
    ECU internal ecu;
    FarmVault internal vault;

    uint256 internal operatorKey = 0xA11CE5;
    address internal operator;
    address internal guardian = address(0x6A12D);
    address internal player = address(0xF00D);
    address internal relayer = address(0xBEEF);

    uint256 internal constant WINDOW_CAP = 100_000e18;
    uint256 internal constant VOUCHER_CAP = 20_000e18;

    function setUp() public {
        operator = vm.addr(operatorKey);
        ecu = new ECU(address(this));
        vault = new FarmVault(ecu, operator, guardian, WINDOW_CAP, VOUCHER_CAP);

        ecu.transfer(address(vault), 1_000_000e18);
        ecu.transfer(player, 10_000e18);
    }

    // -- construction -----------------------------------------------------

    function test_constructorSetsTheCaps() public view {
        assertEq(vault.maxOutflowPerWindow(), WINDOW_CAP);
        assertEq(vault.maxVoucherAmount(), VOUCHER_CAP);
        assertEq(vault.operatorEpoch(), 0);
        assertEq(vault.pendingGuardian(), address(0));
        assertEq(vault.remainingInWindow(), WINDOW_CAP);
    }

    function test_constructorRefusesZeroCaps() public {
        vm.expectRevert(FarmVault.ZeroAmount.selector);
        new FarmVault(ecu, operator, guardian, 0, VOUCHER_CAP);
        vm.expectRevert(FarmVault.ZeroAmount.selector);
        new FarmVault(ecu, operator, guardian, WINDOW_CAP, 0);
    }

    function test_constructorRefusesZeroAddresses() public {
        vm.expectRevert(FarmVault.ZeroAddress.selector);
        new FarmVault(ecu, address(0), guardian, WINDOW_CAP, VOUCHER_CAP);
        vm.expectRevert(FarmVault.ZeroAddress.selector);
        new FarmVault(ecu, operator, address(0), WINDOW_CAP, VOUCHER_CAP);
    }

    // -- deposits ---------------------------------------------------------

    function test_depositPullsAndLogs() public {
        vm.startPrank(player);
        ecu.approve(address(vault), 500e18);

        vm.expectEmit(true, false, false, true, address(vault));
        emit FarmVault.Deposited(player, 500e18);
        vault.deposit(500e18);
        vm.stopPrank();

        assertEq(ecu.balanceOf(player), 9_500e18);
        assertEq(ecu.balanceOf(address(vault)), 1_000_500e18);
    }

    function test_depositNeedsAnAllowance() public {
        vm.prank(player);
        vm.expectRevert();
        vault.deposit(500e18);
    }

    function test_depositRefusesZero() public {
        vm.prank(player);
        vm.expectRevert(FarmVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    /// @dev Pausing the exit must not trap the entrance.
    function test_depositsKeepWorkingWhilePaused() public {
        vm.prank(guardian);
        vault.pauseWithdrawals();

        vm.startPrank(player);
        ecu.approve(address(vault), 100e18);
        vault.deposit(100e18);
        vm.stopPrank();

        assertEq(ecu.balanceOf(address(vault)), 1_000_100e18);
    }

    // -- withdrawals ------------------------------------------------------

    function test_anOperatorVoucherPaysOut() public {
        bytes memory signature = _sign(player, 250e18, 0, block.timestamp + 1 hours);

        vm.prank(relayer); // anyone may submit: the signature is the authority
        vault.withdraw(player, 250e18, 0, block.timestamp + 1 hours, signature);

        assertEq(ecu.balanceOf(player), 10_250e18);
        assertEq(vault.nonces(player), 1);
    }

    function test_aVoucherCannotBeReplayed() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);
        vault.withdraw(player, 250e18, 0, expiry, signature);

        vm.expectRevert(abi.encodeWithSelector(FarmVault.WrongNonce.selector, 1, 0));
        vault.withdraw(player, 250e18, 0, expiry, signature);
    }

    function test_vouchersMustBeSpentInOrder() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory second = _sign(player, 250e18, 1, expiry);

        vm.expectRevert(abi.encodeWithSelector(FarmVault.WrongNonce.selector, 0, 1));
        vault.withdraw(player, 250e18, 1, expiry, second);
    }

    function test_anExpiredVoucherIsRefused() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.warp(expiry + 1);

        vm.expectRevert(abi.encodeWithSelector(FarmVault.VoucherExpired.selector, expiry));
        vault.withdraw(player, 250e18, 0, expiry, signature);
    }

    /// @dev `block.timestamp == expiry` is still valid: the bound is inclusive by design.
    function test_aVoucherIsStillGoodAtTheExactExpiry() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.warp(expiry);
        vault.withdraw(player, 250e18, 0, expiry, signature);
        assertEq(ecu.balanceOf(player), 10_250e18);
    }

    function test_someoneElsesSignatureIsWorthless() public {
        uint256 stranger = 0xDEADBEEF;
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = vault.voucherDigest(player, 250e18, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(stranger, digest);

        vm.expectRevert(FarmVault.BadSignature.selector);
        vault.withdraw(player, 250e18, 0, expiry, abi.encodePacked(r, s, v));
    }

    /// @dev A high-s twin of a valid signature recovers the same key with plain ecrecover;
    ///      OZ's tryRecover rejects it, so a voucher has exactly one valid encoding.
    function test_aMalleableSignatureIsRefused() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = vault.voucherDigest(player, 250e18, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);

        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sHigh = bytes32(n - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;

        vm.expectRevert(FarmVault.BadSignature.selector);
        vault.withdraw(player, 250e18, 0, expiry, abi.encodePacked(r, sHigh, vFlipped));
    }

    /// @dev The amount is signed, so a relayer cannot inflate it on the way through.
    function test_aTamperedAmountIsRefused() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.expectRevert(FarmVault.BadSignature.selector);
        vault.withdraw(player, 5_000e18, 0, expiry, signature);
    }

    /// @dev And so is the recipient: a voucher cannot be redirected.
    function test_aTamperedRecipientIsRefused() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.expectRevert(FarmVault.BadSignature.selector);
        vault.withdraw(relayer, 250e18, 0, expiry, signature);
    }

    /// @dev Replaces the old "any amount the vault holds can be vouchered" fuzz test: the
    ///      per-voucher ceiling is now the bound, not the balance (AUDIT.md finding 2).
    function testFuzz_anyAmountUpToTheVoucherCeilingClears(uint128 amount) public {
        amount = uint128(bound(amount, 1, VOUCHER_CAP));
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, amount, 0, expiry);

        vault.withdraw(player, amount, 0, expiry, signature);

        assertEq(ecu.balanceOf(player), 10_000e18 + amount);
        assertEq(vault.windowOutflow(), amount);
    }

    // -- the caps ---------------------------------------------------------

    function test_aVoucherAboveTheCeilingIsRefusedEvenIfSigned() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, VOUCHER_CAP + 1, 0, expiry);

        vm.expectRevert(abi.encodeWithSelector(FarmVault.VoucherTooLarge.selector, VOUCHER_CAP + 1, VOUCHER_CAP));
        vault.withdraw(player, VOUCHER_CAP + 1, 0, expiry, signature);
    }

    /// @dev The audit's drain: one voucher for the whole custody. Now refused at the ceiling.
    function test_theWholeCustodyCannotLeaveOnOneVoucher() public {
        uint256 all = ecu.balanceOf(address(vault));
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, all, 0, expiry);

        vm.expectRevert();
        vault.withdraw(player, all, 0, expiry, signature);
        assertEq(ecu.balanceOf(address(vault)), all);
    }

    function test_theWindowCapStopsTheSixthVoucher() public {
        uint256 expiry = block.timestamp + 1 hours;
        // Five vouchers of 20,000 fill the 100,000 window exactly.
        for (uint256 i; i < 5; ++i) {
            vault.withdraw(player, VOUCHER_CAP, i, expiry, _sign(player, VOUCHER_CAP, i, expiry));
        }
        assertEq(vault.windowOutflow(), WINDOW_CAP);
        assertEq(vault.remainingInWindow(), 0);

        bytes memory sixth = _sign(player, 1, 5, expiry);
        vm.expectRevert(abi.encodeWithSelector(FarmVault.OutflowCapExceeded.selector, 1, 0));
        vault.withdraw(player, 1, 5, expiry, sixth);
    }

    function test_aPartialWindowOnlyAllowsTheRemainder() public {
        uint256 expiry = block.timestamp + 1 hours;
        vault.withdraw(player, VOUCHER_CAP, 0, expiry, _sign(player, VOUCHER_CAP, 0, expiry));

        vm.prank(guardian);
        vault.setMaxOutflowPerWindow(30_000e18);
        assertEq(vault.remainingInWindow(), 10_000e18);

        bytes memory tooMuch = _sign(player, 10_000e18 + 1, 1, expiry);
        vm.expectRevert(abi.encodeWithSelector(FarmVault.OutflowCapExceeded.selector, 10_000e18 + 1, 10_000e18));
        vault.withdraw(player, 10_000e18 + 1, 1, expiry, tooMuch);

        vault.withdraw(player, 10_000e18, 1, expiry, _sign(player, 10_000e18, 1, expiry));
        assertEq(vault.remainingInWindow(), 0);
    }

    /// @dev Lowering the cap below what already left must not underflow: the window is
    ///      simply full until it rolls over.
    function test_loweringTheCapBelowSpentJustClosesTheWindow() public {
        uint256 expiry = block.timestamp + 1 hours;
        vault.withdraw(player, VOUCHER_CAP, 0, expiry, _sign(player, VOUCHER_CAP, 0, expiry));

        vm.prank(guardian);
        vault.setMaxOutflowPerWindow(1e18);
        assertEq(vault.remainingInWindow(), 0);

        bytes memory one = _sign(player, 1, 1, expiry);
        vm.expectRevert(abi.encodeWithSelector(FarmVault.OutflowCapExceeded.selector, 1, 0));
        vault.withdraw(player, 1, 1, expiry, one);
    }

    function test_theWindowReopensAfterTwentyFourHours() public {
        uint256 expiry = block.timestamp + 1 hours;
        for (uint256 i; i < 5; ++i) {
            vault.withdraw(player, VOUCHER_CAP, i, expiry, _sign(player, VOUCHER_CAP, i, expiry));
        }
        uint256 opened = vault.windowStart();

        vm.warp(opened + 24 hours - 1);
        assertEq(vault.remainingInWindow(), 0);
        uint256 lateExpiry = block.timestamp + 1 hours;
        bytes memory early = _sign(player, 1e18, 5, lateExpiry);
        vm.expectRevert(abi.encodeWithSelector(FarmVault.OutflowCapExceeded.selector, 1e18, 0));
        vault.withdraw(player, 1e18, 5, lateExpiry, early);

        vm.warp(opened + 24 hours);
        assertEq(vault.remainingInWindow(), WINDOW_CAP);
        vault.withdraw(player, 1e18, 5, lateExpiry, _sign(player, 1e18, 5, lateExpiry));
        assertEq(vault.windowStart(), opened + 24 hours);
        assertEq(vault.windowOutflow(), 1e18);
    }

    function test_theGuardianRaisesTheCapsAndOthersCannot() public {
        vm.startPrank(guardian);
        vm.expectEmit(false, false, false, true, address(vault));
        emit FarmVault.MaxOutflowPerWindowChanged(WINDOW_CAP, 2 * WINDOW_CAP);
        vault.setMaxOutflowPerWindow(2 * WINDOW_CAP);
        vault.setMaxVoucherAmount(2 * VOUCHER_CAP);
        vm.stopPrank();
        assertEq(vault.maxOutflowPerWindow(), 2 * WINDOW_CAP);
        assertEq(vault.maxVoucherAmount(), 2 * VOUCHER_CAP);

        vm.startPrank(operator);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.setMaxOutflowPerWindow(1);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.setMaxVoucherAmount(1);
        vm.stopPrank();
    }

    function test_aVoucherCannotOutliveTheLifetimeBound() public {
        uint256 expiry = block.timestamp + vault.MAX_VOUCHER_LIFETIME() + 1;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.expectRevert(
            abi.encodeWithSelector(
                FarmVault.VoucherLifetimeTooLong.selector, expiry, block.timestamp + vault.MAX_VOUCHER_LIFETIME()
            )
        );
        vault.withdraw(player, 250e18, 0, expiry, signature);

        // An unbounded expiry is the audit's case: refused outright, not after a pause.
        bytes memory forever = _sign(player, 250e18, 0, type(uint256).max);
        vm.expectRevert();
        vault.withdraw(player, 250e18, 0, type(uint256).max, forever);
    }

    function test_aVoucherAtExactlyTheLifetimeBoundIsAccepted() public {
        uint256 expiry = block.timestamp + vault.MAX_VOUCHER_LIFETIME();
        vault.withdraw(player, 250e18, 0, expiry, _sign(player, 250e18, 0, expiry));
        assertEq(ecu.balanceOf(player), 10_250e18);
    }

    // -- the guardian -----------------------------------------------------

    function test_pausingStopsWithdrawalsOnly() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.prank(guardian);
        vault.pauseWithdrawals();

        vm.expectRevert(FarmVault.Paused.selector);
        vault.withdraw(player, 250e18, 0, expiry, signature);

        vm.prank(guardian);
        vault.unpauseWithdrawals();
        vault.withdraw(player, 250e18, 0, expiry, signature);
        assertEq(ecu.balanceOf(player), 10_250e18);
    }

    function test_onlyTheGuardianPauses() public {
        vm.prank(player);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.pauseWithdrawals();
    }

    function test_theGuardianCanRotateTheOperator() public {
        uint256 newKey = 0xC0FFEE;
        vm.prank(guardian);
        vault.setOperator(vm.addr(newKey));
        assertEq(vault.operatorEpoch(), 1);

        uint256 expiry = block.timestamp + 1 hours;
        bytes32 digest = vault.voucherDigest(player, 250e18, 0, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newKey, digest);
        vault.withdraw(player, 250e18, 0, expiry, abi.encodePacked(r, s, v));

        assertEq(ecu.balanceOf(player), 10_250e18);
    }

    /// @dev A rotation must invalidate the old key immediately, or a leak is not contained.
    function test_rotatingTheOperatorRetiresTheOldSignatures() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.prank(guardian);
        vault.setOperator(vm.addr(0xC0FFEE));

        vm.expectRevert(FarmVault.BadSignature.selector);
        vault.withdraw(player, 250e18, 0, expiry, signature);
    }

    /// @dev AUDIT.md finding 5: A -> B -> A must not revive what A signed before the roll.
    function test_rotatingBackDoesNotReviveOldVouchers() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signedUnderEpochZero = _sign(player, 250e18, 0, expiry);

        vm.startPrank(guardian);
        vault.setOperator(vm.addr(0xC0FFEE));
        vault.setOperator(operator);
        vm.stopPrank();
        assertEq(vault.operator(), operator);
        assertEq(vault.operatorEpoch(), 2);

        vm.expectRevert(FarmVault.BadSignature.selector);
        vault.withdraw(player, 250e18, 0, expiry, signedUnderEpochZero);

        // The same key, signing under the current epoch, works again.
        vault.withdraw(player, 250e18, 0, expiry, _sign(player, 250e18, 0, expiry));
        assertEq(ecu.balanceOf(player), 10_250e18);
    }

    function test_theEpochIsPartOfTheDigest() public view {
        bytes32 current = vault.voucherDigest(player, 250e18, 0, 1_000);
        assertEq(current, vault.voucherDigest(player, 250e18, 0, 1_000, 0));
        assertNotEq(current, vault.voucherDigest(player, 250e18, 0, 1_000, 1));
    }

    function test_onlyTheGuardianRotates() public {
        vm.prank(player);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.setOperator(player);
    }

    /// @dev AUDIT.md finding 3: nominating is not handing over.
    function test_theGuardianHandOverIsTwoStep() public {
        address next = address(0x5AFE);
        vm.prank(guardian);
        vm.expectEmit(true, true, false, false, address(vault));
        emit FarmVault.GuardianProposed(guardian, next);
        vault.setGuardian(next);

        assertEq(vault.guardian(), guardian);
        assertEq(vault.pendingGuardian(), next);

        // The nominee has no power yet; the incumbent keeps all of it.
        vm.prank(next);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.pauseWithdrawals();
        vm.prank(guardian);
        vault.pauseWithdrawals();
        assertTrue(vault.withdrawalsPaused());

        vm.prank(next);
        vm.expectEmit(true, true, false, false, address(vault));
        emit FarmVault.GuardianChanged(guardian, next);
        vault.acceptGuardian();

        assertEq(vault.guardian(), next);
        assertEq(vault.pendingGuardian(), address(0));
        vm.prank(next);
        vault.unpauseWithdrawals();
        vm.prank(guardian);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.pauseWithdrawals();
    }

    function test_aMistypedGuardianCanBeCorrectedBeforeAcceptance() public {
        vm.startPrank(guardian);
        vault.setGuardian(address(0x1234));
        vault.setGuardian(address(0x5AFE));
        vm.stopPrank();

        vm.prank(address(0x1234));
        vm.expectRevert(FarmVault.NotPendingGuardian.selector);
        vault.acceptGuardian();

        vm.prank(address(0x5AFE));
        vault.acceptGuardian();
        assertEq(vault.guardian(), address(0x5AFE));
    }

    function test_onlyTheNomineeAccepts() public {
        vm.expectRevert(FarmVault.NotPendingGuardian.selector);
        vault.acceptGuardian();

        vm.prank(guardian);
        vault.setGuardian(address(0x5AFE));
        vm.prank(player);
        vm.expectRevert(FarmVault.NotPendingGuardian.selector);
        vault.acceptGuardian();
    }

    function test_onlyTheGuardianNominates() public {
        vm.prank(player);
        vm.expectRevert(FarmVault.NotGuardian.selector);
        vault.setGuardian(player);
        vm.prank(guardian);
        vm.expectRevert(FarmVault.ZeroAddress.selector);
        vault.setGuardian(address(0));
    }

    // -- bumpNonce --------------------------------------------------------

    /// @dev AUDIT.md finding 4 (c): an expired voucher no longer blocks the queue.
    function test_bumpNonceUnblocksAQueue() public {
        uint256 t0 = block.timestamp;
        bytes memory first = _sign(player, 100e18, 0, t0 + 1 hours);
        bytes memory second = _sign(player, 100e18, 1, t0 + 3 days);

        vm.warp(t0 + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(FarmVault.VoucherExpired.selector, t0 + 1 hours));
        vault.withdraw(player, 100e18, 0, t0 + 1 hours, first);
        vm.expectRevert(abi.encodeWithSelector(FarmVault.WrongNonce.selector, 0, 1));
        vault.withdraw(player, 100e18, 1, t0 + 3 days, second);

        vm.prank(operator);
        vm.expectEmit(true, true, false, true, address(vault));
        emit FarmVault.NonceBumped(player, 0, 1, operator);
        vault.bumpNonce(player);

        vault.withdraw(player, 100e18, 1, t0 + 3 days, second);
        assertEq(ecu.balanceOf(player), 10_100e18);
    }

    /// @dev AUDIT.md finding 4 (a): a signed voucher can be voided for one recipient
    ///      without pausing everyone.
    function test_bumpNonceVoidsASignedVoucher() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _sign(player, 250e18, 0, expiry);

        vm.prank(guardian);
        vault.bumpNonce(player);

        vm.expectRevert(abi.encodeWithSelector(FarmVault.WrongNonce.selector, 1, 0));
        vault.withdraw(player, 250e18, 0, expiry, signature);
        assertEq(vault.nonces(player), 1);
    }

    function test_onlyTheGuardianOrOperatorBumps() public {
        vm.prank(player);
        vm.expectRevert(FarmVault.NotGuardianOrOperator.selector);
        vault.bumpNonce(player);
        vm.prank(relayer);
        vm.expectRevert(FarmVault.NotGuardianOrOperator.selector);
        vault.bumpNonce(player);
    }

    // -- the domain -------------------------------------------------------

    /// @dev The backend rebuilds this digest to sign vouchers, so the domain must be the
    ///      one app/api/signing.py uses: "e-Farm", version "1", this chain, this contract.
    function test_theDomainIsTheGames() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("e-Farm")),
                keccak256(bytes("1")),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.domainSeparator(), expected);
    }

    function test_theVoucherTypeCarriesTheEpoch() public view {
        assertEq(
            vault.VOUCHER_TYPEHASH(),
            keccak256("WithdrawalVoucher(address to,uint256 amount,uint256 nonce,uint256 expiry,uint256 epoch)")
        );
    }

    function _sign(address to, uint256 amount, uint256 nonce, uint256 expiry) internal view returns (bytes memory) {
        bytes32 digest = vault.voucherDigest(to, amount, nonce, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
