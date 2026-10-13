// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FarmVault -- custody for the game-side half of the supply
/// @notice ECU enters by deposit and leaves only against a voucher the game's operator
///         signed (ECONOMY.md §1, §11.7).
///
/// @dev **What this contract is.** §11.7 calls the Vault "a rollup, not a fourth balance":
///      the Co-op reserve and the Bank pool -- 50 % of supply -- sit here as one ERC-20
///      balance, and the off-chain ledger is the authority on how that balance divides
///      between farms, reserves and escrows. This contract therefore deliberately knows
///      nothing about farms, buckets or the economy. It moves tokens in, and it moves them
///      out when the operator says so.
///
///      **Deposits are open and permissionless.** `deposit` pulls an approved amount and
///      emits `Deposited`, which the backend watches to credit the sending wallet's farm
///      (a wallet maps to at most one farm). A plain ERC-20 transfer straight to this
///      address also arrives, and is creditable from the token's own Transfer event; the
///      function exists so that the common path emits one unambiguous log.
///
///      **Withdrawals are operator-signed vouchers.** The game decides who may take what:
///      it applies the aged-harvest toll, the daily cap, the 48-hour delay and the risk
///      state (§11.1, §12) off-chain, and only then signs. A voucher carries the
///      recipient, the amount, a per-recipient nonce, an expiry and the operator epoch it
///      was signed under, so it cannot be replayed, reordered, held indefinitely or
///      revived by a later key rotation. This is a *different signature* from the one a
///      player's wallet makes when requesting a withdrawal in the API: that proves intent
///      to the game, this proves authorisation to the chain.
///
///      **Outflow is bounded on chain.** The operator is a hot key, so the chain does not
///      trust it with the whole custody at once: a voucher may not exceed
///      `maxVoucherAmount`, the sum of withdrawals inside one 24-hour window may not exceed
///      `maxOutflowPerWindow`, and a voucher may not be valid for longer than
///      `MAX_VOUCHER_LIFETIME` after submission. A legitimate surge waits for the next
///      window or a guardian raise; a leaked key is limited to one window's budget before
///      the guardian pauses or rotates.
///
///      **Pausing covers withdrawals only.** A guardian -- a 2-of-3 multisig -- can stop
///      the exit if a key leaks or the backend misbehaves, without trapping deposits or
///      touching the token. The threshold lives in the multisig, not here: this contract
///      holds one guardian address and lets the Safe supply the "2 of 3", which keeps the
///      signing policy changeable without redeploying custody.
///
///      **Trust assumptions, stated plainly.**
///      - The guardian has, in effect, custody up to the caps: `setOperator` has no delay,
///        so whoever controls the guardian can appoint a key it holds and sign vouchers
///        for itself, bounded only by `maxVoucherAmount` and `maxOutflowPerWindow`, which
///        the guardian can also raise. A guardian hand-over is therefore a custody
///        hand-over, which is why it is two-step and why the guardian must be a Safe.
///      - The operator must be an EOA. Vouchers are verified with `ECDSA.tryRecover` only
///        (65-byte signatures, high-s rejected); there is no ERC-1271 path, so a contract
///        operator can never produce a valid voucher until the guardian rotates to an EOA.
///        This is deliberate: the signer is the backend's hot key, not a wallet contract.
///      - The guardian can pause withdrawals indefinitely while deposits keep flowing.
///        Pausing is one-way for depositors in that sense; the token itself is never
///        paused and the guardian cannot move tokens except through a voucher.
///      - The guardian or operator can void a recipient's queue with `bumpNonce`. That is
///        a power to refuse a signed-but-unspent payment, not to take one.
contract FarmVault is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The token this vault custodies.
    IERC20 public immutable ecu;

    /// @notice Length of one outflow window.
    uint256 public constant OUTFLOW_WINDOW = 24 hours;

    /// @notice A voucher may not be valid for longer than this after the block it is
    ///         submitted in. Bounds how long a leaked or mistaken signature stays live.
    uint256 public constant MAX_VOUCHER_LIFETIME = 7 days;

    /// @notice Signs withdrawal vouchers. Rotatable by the guardian if a key is lost.
    address public operator;

    /// @notice Incremented on every operator rotation and bound into each voucher, so a
    ///         voucher signed under an earlier operator stays invalid even if that key is
    ///         ever installed again.
    uint256 public operatorEpoch;

    /// @notice The 2-of-3 multisig that may pause withdrawals and rotate the operator.
    address public guardian;

    /// @notice The address `setGuardian` nominated; becomes guardian on `acceptGuardian`.
    address public pendingGuardian;

    /// @notice True while withdrawals are stopped. Deposits are never paused.
    bool public withdrawalsPaused;

    /// @notice The most ECU that may leave within one `OUTFLOW_WINDOW`. Guardian-settable.
    uint256 public maxOutflowPerWindow;

    /// @notice The most ECU a single voucher may carry. Guardian-settable.
    uint256 public maxVoucherAmount;

    /// @notice Start of the window `windowOutflow` is counted in.
    uint256 public windowStart;

    /// @notice ECU withdrawn since `windowStart`.
    uint256 public windowOutflow;

    /// @notice Next expected voucher nonce for each recipient.
    mapping(address => uint256) public nonces;

    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("WithdrawalVoucher(address to,uint256 amount,uint256 nonce,uint256 expiry,uint256 epoch)");

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount, uint256 nonce);
    event OperatorChanged(address indexed previousOperator, address indexed newOperator, uint256 epoch);
    event GuardianProposed(address indexed currentGuardian, address indexed pendingGuardian);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event WithdrawalsPaused(address indexed by);
    event WithdrawalsUnpaused(address indexed by);
    event MaxOutflowPerWindowChanged(uint256 previous, uint256 current);
    event MaxVoucherAmountChanged(uint256 previous, uint256 current);
    event NonceBumped(address indexed to, uint256 previous, uint256 current, address indexed by);

    error ZeroAddress();
    error ZeroAmount();
    error NotGuardian();
    error NotGuardianOrOperator();
    error NotPendingGuardian();
    error Paused();
    error VoucherExpired(uint256 expiry);
    error VoucherLifetimeTooLong(uint256 expiry, uint256 latestAllowed);
    error VoucherTooLarge(uint256 amount, uint256 maxVoucherAmount);
    error OutflowCapExceeded(uint256 requested, uint256 remainingInWindow);
    error WrongNonce(uint256 expected, uint256 given);
    error BadSignature();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// @param ecu_ The ECU token.
    /// @param operator_ The backend key that signs withdrawal vouchers. Must be an EOA.
    /// @param guardian_ The 2-of-3 multisig that can pause withdrawals.
    /// @param maxOutflowPerWindow_ Initial cap on ECU leaving within one 24-hour window.
    /// @param maxVoucherAmount_ Initial cap on the amount of a single voucher.
    constructor(
        IERC20 ecu_,
        address operator_,
        address guardian_,
        uint256 maxOutflowPerWindow_,
        uint256 maxVoucherAmount_
    ) EIP712("e-Farm", "1") {
        if (address(ecu_) == address(0) || operator_ == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        if (maxOutflowPerWindow_ == 0 || maxVoucherAmount_ == 0) revert ZeroAmount();
        ecu = ecu_;
        operator = operator_;
        guardian = guardian_;
        maxOutflowPerWindow = maxOutflowPerWindow_;
        maxVoucherAmount = maxVoucherAmount_;
        emit OperatorChanged(address(0), operator_, 0);
        emit GuardianChanged(address(0), guardian_);
        emit MaxOutflowPerWindowChanged(0, maxOutflowPerWindow_);
        emit MaxVoucherAmountChanged(0, maxVoucherAmount_);
    }

    // -----------------------------------------------------------------------
    // Deposits
    // -----------------------------------------------------------------------

    /// @notice Bridge ECU into the game. Requires an allowance for this contract.
    /// @dev Never paused: stopping the exit must not also trap the entrance, and a player
    ///      who has already approved should not have a transaction fail for a reason that
    ///      has nothing to do with them.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        ecu.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    // -----------------------------------------------------------------------
    // Withdrawals
    // -----------------------------------------------------------------------

    /// @notice Take ECU out against a voucher the operator signed under the current epoch.
    /// @dev Anyone may submit the transaction -- a relayer, or the recipient -- because the
    ///      signature, not the sender, is the authority, and the tokens can only ever go to
    ///      the `to` the operator named. The voucher is checked against the caps before
    ///      anything moves; the nonce and the window counter are spent before the transfer.
    function withdraw(address to, uint256 amount, uint256 nonce, uint256 expiry, bytes calldata signature)
        external
        nonReentrant
    {
        if (withdrawalsPaused) revert Paused();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > maxVoucherAmount) revert VoucherTooLarge(amount, maxVoucherAmount);
        if (block.timestamp > expiry) revert VoucherExpired(expiry);
        uint256 latestAllowed = block.timestamp + MAX_VOUCHER_LIFETIME;
        if (expiry > latestAllowed) revert VoucherLifetimeTooLong(expiry, latestAllowed);

        uint256 expected = nonces[to];
        if (nonce != expected) revert WrongNonce(expected, nonce);

        bytes32 digest = _digest(to, amount, nonce, expiry, operatorEpoch);
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || signer != operator) revert BadSignature();

        // The window cap, checked before the transfer. A window opens on the first
        // withdrawal after the previous one closed, so at most two windows' worth can
        // leave in any 24 hours, and never more than one cap inside a single window.
        uint256 spent = windowOutflow;
        if (block.timestamp >= windowStart + OUTFLOW_WINDOW) {
            windowStart = block.timestamp;
            spent = 0;
        }
        uint256 cap = maxOutflowPerWindow;
        if (amount > cap - _min(spent, cap)) revert OutflowCapExceeded(amount, cap - _min(spent, cap));
        windowOutflow = spent + amount;

        // Spent before the transfer: the nonce is the replay guard, so it must move even
        // if the token does something surprising on the way out.
        nonces[to] = expected + 1;

        emit Withdrawn(to, amount, nonce);
        ecu.safeTransfer(to, amount);
    }

    /// @notice The digest a voucher must be signed over, under the current operator epoch.
    ///         For the backend and for testing.
    function voucherDigest(address to, uint256 amount, uint256 nonce, uint256 expiry) external view returns (bytes32) {
        return _digest(to, amount, nonce, expiry, operatorEpoch);
    }

    /// @notice The digest for an explicit epoch, so a client can show what an old voucher
    ///         was signed over without the contract's current state.
    function voucherDigest(address to, uint256 amount, uint256 nonce, uint256 expiry, uint256 epoch)
        external
        view
        returns (bytes32)
    {
        return _digest(to, amount, nonce, expiry, epoch);
    }

    /// @notice The EIP-712 domain separator, so a client can rebuild it without guessing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice How much may still leave in the current window, without changing state.
    function remainingInWindow() external view returns (uint256) {
        if (block.timestamp >= windowStart + OUTFLOW_WINDOW) return maxOutflowPerWindow;
        uint256 cap = maxOutflowPerWindow;
        return cap - _min(windowOutflow, cap);
    }

    // -----------------------------------------------------------------------
    // Guardian and operator
    // -----------------------------------------------------------------------

    function pauseWithdrawals() external onlyGuardian {
        withdrawalsPaused = true;
        emit WithdrawalsPaused(msg.sender);
    }

    function unpauseWithdrawals() external onlyGuardian {
        withdrawalsPaused = false;
        emit WithdrawalsUnpaused(msg.sender);
    }

    /// @notice Rotate the signing key, for a leak or a planned roll.
    /// @dev Bumps the operator epoch, so every voucher signed before the rotation stops
    ///      working immediately and stays dead even if the same key is installed again.
    ///      Unspent nonces are untouched, so a queue signed before a rotation must be
    ///      reissued -- which is the safe direction to fail in.
    function setOperator(address newOperator) external onlyGuardian {
        if (newOperator == address(0)) revert ZeroAddress();
        uint256 epoch = ++operatorEpoch;
        emit OperatorChanged(operator, newOperator, epoch);
        operator = newOperator;
    }

    /// @notice Nominate the next guardian. Nothing changes until it calls `acceptGuardian`.
    /// @dev Two-step on purpose: the outgoing guardian keeps every power until the new
    ///      address has proven it can transact, so a typo or a Safe that only exists on
    ///      another chain cannot strand pause and rotation.
    function setGuardian(address newGuardian) external onlyGuardian {
        if (newGuardian == address(0)) revert ZeroAddress();
        pendingGuardian = newGuardian;
        emit GuardianProposed(msg.sender, newGuardian);
    }

    /// @notice Complete a hand-over started by `setGuardian`.
    function acceptGuardian() external {
        if (msg.sender != pendingGuardian) revert NotPendingGuardian();
        emit GuardianChanged(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
    }

    /// @notice Set the most ECU that may leave within one 24-hour window.
    function setMaxOutflowPerWindow(uint256 newCap) external onlyGuardian {
        emit MaxOutflowPerWindowChanged(maxOutflowPerWindow, newCap);
        maxOutflowPerWindow = newCap;
    }

    /// @notice Set the most ECU a single voucher may carry.
    function setMaxVoucherAmount(uint256 newCap) external onlyGuardian {
        emit MaxVoucherAmountChanged(maxVoucherAmount, newCap);
        maxVoucherAmount = newCap;
    }

    /// @notice Void the next unspent voucher of one recipient by skipping its nonce.
    /// @dev Lets the game refuse a payment it signed and then changed its mind about -- a
    ///      farm frozen after signing, a corrected amount, an expired voucher blocking the
    ///      queue -- without pausing everyone or rotating the operator. Callable by the
    ///      operator because it is the one that signs and corrects vouchers, and by the
    ///      guardian so a lost operator key does not leave a queue stuck.
    function bumpNonce(address to) external {
        if (msg.sender != guardian && msg.sender != operator) revert NotGuardianOrOperator();
        uint256 previous = nonces[to];
        nonces[to] = previous + 1;
        emit NonceBumped(to, previous, previous + 1, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _digest(address to, uint256 amount, uint256 nonce, uint256 expiry, uint256 epoch)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(VOUCHER_TYPEHASH, to, amount, nonce, expiry, epoch)));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
