# Adaptation for launch

What changed in this repository to make it launchable, file by file, and which rule or
AUDIT.md finding required it. Findings are numbered as AUDIT.md lists them (1–11).
Every finding was reproduced against the tree as it arrived before it was acted on; the
reproductions are summarised under each item.

## Reproduction of the audit

| # | Finding | Reproduced? | Action |
|---|---|---|---|
| 1 | `Distribute.run()` mints to `address(this)`, cannot broadcast | Yes: `forge script script/Distribute.s.sol:Distribute` with the six env vars refused the script with "Usage of address(this) detected in script contract"; a test calling `run()` reverted `ERC20InsufficientBalance` for the default broadcaster | Fixed (A) |
| 2 | No outflow bound: one voucher drains the custody | Yes: a voucher for the vault's whole balance cleared in one `withdraw` | Fixed (C) |
| 3 | `setGuardian` is single-step | Yes: `setGuardian(0x1234)` replaced the guardian at once and the old guardian lost `pauseWithdrawals` | Fixed (C) |
| 4 | Vouchers irrevocable, unbounded expiry, stuck queue | Yes: `expiry = type(uint256).max` was accepted and paid after a pause/unpause and a ten-year warp; an expired nonce 0 blocked nonce 1 | Fixed (C) |
| 5 | Rotating the operator back revives old vouchers | Yes: A → B → A made A's pre-rotation voucher valid again | Fixed (C) |
| 6 | No cliff; ~54,800 ECU releasable on day one | Yes: `releasable` was 13,698.63 (team) + 41,095.89 (community) ECU at `start + 1 days` | Fixed (B) |
| 7 | 15 % LP slice sent unlocked to a plain address | Yes: `LIQUIDITY_ADDRESS` could transfer the 15 M on the launch block | Fixed (A)/(D): slice removed, pool is factory-owned |
| 8 | Vesting beneficiary can renounce and strand the slice | Yes: `renounceOwnership()` then `release(token)` reverted with `ERC20InvalidReceiver` | Fixed (B) |
| 9 | Trust assumptions undocumented (guardian custody, EOA-only operator, one-way pause) | Yes, as described: these are the agreed design, not bypasses | Documented in NatSpec and README (C) |
| 10 | Tests never exercise broadcast or any bound; fuzz test encodes the unbounded voucher | Yes: 41/41 passed on the old tree while the audit's proofs failed | Fixed (E) |
| 11 | Shares computed from a hard-coded 100 M total, not the balance received | Yes: porting `_slice` over a 75 M balance reverted on the vault transfer | Fixed (A) |

Nothing in the audit failed to reproduce.

## Changes

### (A) `src/Distributor.sol` (new) and `script/Distribute.s.sol` (rewritten) — findings 1, 7, 11

- **`Distributor`** holds four immutable targets set in its constructor (`vault`,
  `teamVesting`, `communityVesting`, `listings`) and a permissionless `distribute()` that
  runs once. It reads `balanceOf(address(this))` at call time and sends 50/75 to the
  vault, 15/75 to team vesting, 5/75 to community vesting and the exact remainder to
  listings, so rounding dust is never stranded and the same code serves both the dry run
  (100 % arrives) and the mainnet custom_token launch (75 % arrives as `remainderTo`).
  A call with nothing to split reverts without consuming the shot, so a griefer cannot
  burn it before the token arrives. The constructor makes no external call (the token is
  read from `FarmVault.ecu()` inside `distribute()`), so it deploys on the empty chain
  the launch rehearsal uses and before the vault has code.
- **`Distribute.s.sol`** no longer holds any supply or reads `address(this)`. It reads
  five addresses from env with no defaults (`COMMUNITY_BENEFICIARY`, `TEAM_BENEFICIARY`,
  `LISTINGS_MULTISIG`, `VAULT_OPERATOR`, `VAULT_GUARDIAN`), deploys from the broadcaster
  in the order team vesting, community vesting, vault, Distributor, ECU (minted to the
  Distributor), then calls `distribute()`. The vault's immutable token address is derived
  from the broadcaster's nonce with `vm.computeCreateAddress` and asserted after the ECU
  creation. `deployAll` takes the deployer explicitly so tests can drive it. The
  `LIQUIDITY_ADDRESS` env var and the LP transfer are gone (finding 7): the pool will be a
  factory-owned single-sided V4 position. Initial vault caps are named constants
  (`INITIAL_MAX_OUTFLOW_PER_WINDOW` = 250 000 ECU, `INITIAL_MAX_VOUCHER_AMOUNT` =
  50 000 ECU), chosen as a number the brief left open and listed in README.
- **`src/ECU.sol`** is unchanged: it still mints the whole supply to the `distributor`
  constructor argument, which is now a contract. On mainnet the custom_token launch
  creates the token; that is a later launch and is not adapted here.
- **Deployment order for a factory manifest.** `TeamVesting(beneficiary, start)` and
  `CommunityVesting(beneficiary, start)` have no dependencies; `FarmVault(ecu, operator,
  guardian, maxOutflowPerWindow, maxVoucherAmount)` needs the token address;
  `Distributor(vault, teamVesting, communityVesting, listings)` needs the three before it.
  `ECU(distributor)` and `FarmVault(ecu, …)` reference each other, so a single factory
  transaction that creates all five with backward references cannot exist: the token must
  already exist (the Sepolia dry-run script, which resolves the cycle with the nonce, or
  the mainnet custom_token launch), and the other four then reference it backward. Every
  constructor is nonpayable, takes only static arguments (at most five), and calls no
  contract.

### (B) `src/TeamVesting.sol` and `src/CommunityVesting.sol` (new) — findings 6, 8

- `TeamVesting is VestingWalletCliff`: 36 months (`3 * 365 days`) with a 12-month
  (`365 days`) cliff. `CommunityVesting is VestingWallet`: 12 months linear, no cliff.
  Both take `(beneficiary, startTimestamp)`; the durations are constants.
- Both override `renounceOwnership()` to revert `RenounceDisabled()`; `transferOwnership`
  stays so a Safe can migrate to a new Safe. Their constructors are nonpayable although
  OpenZeppelin's base is payable, so the factory's zero-value deployment is the only one
  that succeeds.
- `.env.example` is **not** modified: `.env` files are outside this task's allowed paths
  (the previous attempt was rejected for touching it). The wording the brief asked for —
  the beneficiary is a transferable owner that must be a Safe, not an address that
  "cannot be changed", and `LIQUIDITY_ADDRESS` is no longer read — is in README.md under
  "Launch distribution and the Sepolia dry run" instead, and should be copied into
  `.env.example` by the requester.

### (C) `src/FarmVault.sol` — findings 2, 3, 4, 5, 9

- **Caps.** `maxOutflowPerWindow` (guardian-settable, `setMaxOutflowPerWindow`) is checked
  in `withdraw()` before the transfer against a 24-hour window (`OUTFLOW_WINDOW`) that
  opens on the first withdrawal after the previous one closed; `maxVoucherAmount`
  (guardian-settable, `setMaxVoucherAmount`) bounds a single voucher;
  `MAX_VOUCHER_LIFETIME = 7 days` bounds `expiry` relative to the submission block. Both
  caps are constructor arguments and must be non-zero there. `remainingInWindow()` is a
  view for the backend. Lowering the cap below what already left in the window cannot
  underflow; the window is simply full until it rolls over.
- **Two-step guardian.** `setGuardian(next)` now only records `pendingGuardian` and emits
  `GuardianProposed`; `acceptGuardian()` from the nominee completes the hand-over and emits
  `GuardianChanged`. The incumbent keeps every power until then and can re-nominate.
- **`bumpNonce(address to)`**, callable by the guardian or the operator, skips one
  recipient's next nonce so an expired, withheld or regretted voucher can be voided
  without a global pause or rotation.
- **Operator epoch.** `operatorEpoch` is incremented by `setOperator` and is the fifth
  field of the signed struct: `VOUCHER_TYPEHASH` is now
  `WithdrawalVoucher(address to,uint256 amount,uint256 nonce,uint256 expiry,uint256 epoch)`.
  `withdraw` hashes with the current epoch, so its calldata is unchanged for relayers;
  `voucherDigest(to, amount, nonce, expiry)` uses the current epoch and a five-argument
  overload takes an explicit one. **The backend's signer must add the `epoch` field to its
  EIP-712 type** and read `operatorEpoch()` after every rotation.
- Verification stays `ECDSA.tryRecover` only (EOA operator, no ERC-1271). The trust
  assumptions of finding 9 — guardian custody via instant `setOperator`, EOA-only
  operator, indefinite pause with deposits open, the nonce bump as a refusal power — are
  stated in the contract NatSpec and README.
- `OperatorChanged` gained an `epoch` argument; the constructor emits the initial
  operator, guardian and cap events so indexers see the starting state.

### (D) `docs/ECONOMY.md` §9 and §11.7

- §9 supply row: pool 15 % (factory-owned single-sided V4 position), swarm 10 %, vault
  50 % (35 % Co-op reserve + 15 % Bank pool), team 15 % (12 m cliff / 36 m), community
  5 % (12 m linear), listings 5 %. The "DEX LP (locked 2 y)" entry is gone.
- §11.7 table rewritten to the same split, with a paragraph on the Distributor and the
  statement that factory custody of the pool position replaces the LP lock. The two
  "consequences" bullets were updated for the swarm slice and the day-one vesting amounts.
  §11.6's wording about treasury-provided liquidity was left as it was; it is outside
  the two sections the brief named.

### (E) Tests — finding 10

- `test/FarmVault.t.sol`: constructor updated for the caps. Removed
  `testFuzz_anyAmountTheVaultHoldsCanBeVouchered` (it encoded the unbounded voucher) and
  replaced it with `testFuzz_anyAmountUpToTheVoucherCeilingClears`. Rewrote
  `test_theGuardianCanHandOver` as `test_theGuardianHandOverIsTwoStep` (the old one
  encoded the single-step hand-over). Added: per-voucher ceiling, whole-custody drain
  refused, window cap on the sixth voucher, partial-window remainder, cap lowered below
  spent, window reopening at exactly 24 h, guardian-only cap setters, lifetime bound
  (over, exact, and `type(uint256).max`), exact-expiry acceptance, high-s malleability
  refused, epoch rotate-back, epoch in the digest and typehash, two-step guardian with
  re-nomination and nominee-only accept, `bumpNonce` unblocking a queue and voiding a
  signed voucher, and its access control.
- `test/Distribute.t.sol`: `setUp` sets the env vars and calls `script.run()`, so every
  test runs on a deployment made under `vm.startBroadcast()`. Removed the LP test and
  the old 15/15/15/5/50 expectations; added: the script, the test and the broadcaster
  hold nothing, the mint went to the Distributor, the 50/15/5/remainder split, the
  distributor cannot run twice, the cliff timestamp, day-one amounts (team 0, community
  one 365th), the third unlocking at the cliff and nothing one second before, vault
  wiring including the initial caps.
- `test/Distributor.t.sol` (new): the mainnet 75 M case gives 50/15/5/5 M, the 100 M case
  keeps the proportions, a fuzz over any received amount asserts the four outputs sum to
  it exactly with the dust in listings, runs-once, nothing-to-distribute does not consume
  the shot, zero targets refused, constructs before the vault has code, no owner.
- `test/Vesting.t.sol` (new): fixed schedules, day-one amounts, cliff boundary, linearity
  after the cliff, community linear with no cliff, a fuzz over elapsed time against the
  closed-form schedule, renounce disabled on both, transfer kept and paying the new
  owner, owner-only transfer, zero beneficiary refused, constructors not payable.
- `test/ECU.t.sol` is unchanged. The suite has no inter-test state and no fixed-order
  dependency; `vm.setEnv` is only called with the same values in `setUp`.

### Launch-rule checks

- No contract is owned by `msg.sender` or `tx.origin`: ECU and Distributor have no owner;
  the vault's guardian and operator, and the vesting beneficiaries, are constructor
  arguments. For the dry run the brief fills all of them, and the listings address, with
  the owner wallet.
- No minting after launch, no pause/freeze/blacklist on the token, no proxies, no
  `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT` in any runtime (scanned with the same
  PUSH-skipping walk the protected floor uses); the largest runtime is 5.4 KB.
- `FarmVault.pauseWithdrawals` pauses the vault's exit, not the token, and the brief asks
  for it; it is kept and documented as a trust assumption.
- `foundry.toml`, `remappings.txt`, `lib/`, `.gitmodules`, `.env*`, `.git/` and `.github/`
  were not touched. No dependency was added; `VestingWalletCliff` ships with the vendored
  OpenZeppelin 5.7.0.
- `launch.json` is not written.

### Verification

`forge build` and `forge test` pass with forge 1.8.3, including with
`FOUNDRY_FUZZ_SEED=0x1d39a560567aa540b142a3c4b1d847ed28f29bdef053bb93b606120500cc0af2`.
`forge script script/Distribute.s.sol:Distribute` with the five env vars set simulates to
completion without an RPC and reports the five addresses.
