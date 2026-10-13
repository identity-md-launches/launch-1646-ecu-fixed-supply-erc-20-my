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

### (A) `src/Distributor.sol`, `src/DistributorBase.sol`, `src/TokenDistributor.sol` and `script/Distribute.s.sol` — findings 1, 7, 11, and the launch cycle

- **The cycle, and why a root contract resolves it.** `ECU(distributor)` mints its whole
  supply to the Distributor, `FarmVault(ecu, …)` fixes the token as an immutable, and the
  Distributor fixes the vault. As separate creations those three reference each other
  forward, which only a nonce prediction can satisfy, and a launch manifest that deploys
  bytecode has no nonce to predict (the first version of this adaptation ordered the
  five creations by the broadcaster's nonce and was stopped at the manifest for exactly
  that reason). The resolution is a single root: `Distributor`'s constructor creates
  everything itself, so `address(this)` is known before the token exists and the token
  before the vault, in one atomic transaction.
- **`DistributorBase`** (abstract) holds the shared constructor and the split. Given a
  zero `token_` it creates `ECU(address(this))`, then `FarmVault(token, operator,
  guardian, maxOutflowPerWindow, maxVoucherAmount)`, then `TeamVesting(teamBeneficiary,
  block.timestamp)` and `CommunityVesting(communityBeneficiary, block.timestamp)`, emits
  one `Launched(token, vault, teamVesting, communityVesting, listings)` and splits the
  minted balance 50/75 to the vault, 15/75 to team vesting, 5/75 to community vesting and
  the exact remainder to listings, emitting `Distributed`. The Distributor ends with a
  zero balance and `distributed == true`. Given a non-zero `token_` it skips token
  creation, makes **no call to the token**, creates the same three contracts and defers
  the split to a permissionless one-shot `distribute()` that reverts
  `InsufficientBalance(held, expected)` until at least `expectedBalance` is held, then
  splits everything held. The created addresses are public immutables (`token`, `vault`,
  `teamVesting`, `communityVesting`) with `listings` and `expectedBalance`.
- **`Distributor`** is the token-creating mode and the one contract the manifest lists:
  `Distributor(operator, guardian, teamBeneficiary, communityBeneficiary, listings,
  maxOutflowPerWindow, maxVoucherAmount)` — seven static arguments, nonpayable, no owner,
  no call to any pre-existing contract. Solidity has no constructor overloads, so the
  "overload" is a second contract on the same base.
- **`TokenDistributor`** is the deferred mode for the mainnet custom_token launch:
  `TokenDistributor(token, expectedBalance, operator, guardian, teamBeneficiary,
  communityBeneficiary, listings, maxOutflowPerWindow, maxVoucherAmount)`. It refuses a
  zero token (which would otherwise select token-creating mode) and a zero
  `expectedBalance`. It is deployed before the launch so its address can be the launch's
  `remainderTo`; the expected value for the ECU plan is 75 % of the token's supply.
- Shares are fractions of what arrives, not of a hard-coded total (finding 11), so the
  same base serves the dry run (100 % arrives) and mainnet (75 % arrives). Rounding dust
  goes to listings, so nothing is stranded.
- **`Distribute.s.sol`** reduces to `new Distributor(...)`. `run()` reads five addresses
  from the environment with no default (`VAULT_OPERATOR`, `VAULT_GUARDIAN`,
  `TEAM_BENEFICIARY`, `COMMUNITY_BENEFICIARY`, `LISTINGS_MULTISIG`) and calls
  `deploy(Destinations)`, which broadcasts the one creation; tests call `deploy()`
  directly and never touch the environment. The script never holds supply or reads
  `address(this)` (finding 1). There is no `distribute()` call. `LIQUIDITY_ADDRESS` and
  the LP transfer are gone (finding 7): the pool will be a factory-owned single-sided V4
  position. Initial vault caps are named constants (`INITIAL_MAX_OUTFLOW_PER_WINDOW` =
  250 000 ECU, `INITIAL_MAX_VOUCHER_AMOUNT` = 50 000 ECU), chosen as a number the brief
  left open and listed in README.
- **`src/ECU.sol`** is unchanged: it still mints the whole supply to the `distributor`
  constructor argument, which the root passes as `address(this)`.
- **Runtime size.** The root embeds the init code of the four contracts it creates:
  `Distributor` runtime is 18 455 bytes and `TokenDistributor` 18 537, under the 24 576
  EIP-170 limit with the project's `optimizer_runs = 200`.

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
- `test/Distribute.t.sol`: `setUp` calls `script.deploy(destinations)`, so every test
  runs on the one creation made under `vm.startBroadcast()`; no test reads or sets the
  environment. Checks: the script, the test, the broadcaster and the Distributor hold
  nothing; the Distributor is the broadcaster's creation, not the script's; the
  50/15/5/remainder split; destinations and initial caps; vesting schedules start at
  deployment; the dry-run configuration with one wallet in every seat; a zero
  destination is refused.
- `test/Distributor.t.sol`: token-creating mode. The constructor creates all four
  contracts and exposes them; the whole supply is minted and split at once and the root
  ends empty; conservation; `Launched` and `Distributed` emitted with the five addresses
  predicted ahead of the creation; `distribute()` reverts `AlreadyDistributed` even after
  tokens arrive later; vault wiring, keys and caps; a signed voucher pays out of the
  vault's slice; vesting owners, start, duration and cliff; nothing vested at launch;
  a third at the cliff; payout at the end; renounce disabled; zero listings, operator,
  guardian, caps and beneficiaries each refused with the creating contract's error; a
  reverted launch leaves no token behind; no owner; shares sum to the denominator; a fuzz
  over all seven arguments asserts the destinations and conservation.
- `test/TokenDistributor.t.sol` (new): deferred mode. Token creation skipped and the
  vault wired to the given token; constructs before the token has code; `Launched`
  emitted; zero token, zero expected balance, zero listings, zero keys and caps refused;
  the mainnet 75 M case gives 50/15/5/5 M from a permissionless caller; below the
  expected balance refused without consuming the shot and succeeding once the last unit
  arrives; over-delivery split in full; runs once; a fuzz over any received amount at or
  above the expectation asserts the sum and the dust; a fuzz over any shortfall asserts
  refusal; a voucher pays out of the distributed slice; no owner.
- `test/Vesting.t.sol` (new): fixed schedules, day-one amounts, cliff boundary, linearity
  after the cliff, community linear with no cliff, a fuzz over elapsed time against the
  closed-form schedule, renounce disabled on both, transfer kept and paying the new
  owner, owner-only transfer, zero beneficiary refused, constructors not payable.
- `test/ECU.t.sol`, `test/FarmVault.t.sol` and `test/Vesting.t.sol` are unchanged. The
  suite has no inter-test state, no fixed-order dependency and no `vm.env*` / `vm.setEnv`
  call, so it runs in any order, in parallel and with an empty environment.

### Launch-rule checks

- The manifest lists one contract, `Distributor`, with seven constructor arguments; its
  constructor calls no pre-existing contract (the only calls are to the contracts it
  creates in the same transaction), so it runs on an empty chain. `TokenDistributor`'s
  constructor calls nothing at all.
- No contract is owned by `msg.sender` or `tx.origin`: ECU and the Distributor have no
  owner; the vault's guardian and operator, and the vesting beneficiaries, are
  constructor arguments. For the dry run the brief fills all of them, and the listings
  address, with the owner wallet.
- No minting after launch, no pause/freeze/blacklist on the token, no proxies, no
  `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT` in any runtime (scanned with the same
  PUSH-skipping walk the protected floor uses); the largest runtime is 5.4 KB.
- `FarmVault.pauseWithdrawals` pauses the vault's exit, not the token, and the brief asks
  for it; it is kept and documented as a trust assumption.
- `foundry.toml`, `remappings.txt`, `lib/`, `.gitmodules`, `.env*`, `.git/` and `.github/`
  were not touched. No dependency was added; `VestingWalletCliff` ships with the vendored
  OpenZeppelin 5.7.0.
- `launch.json` is not written.

### Assumptions and open items

- The custom_token launch delivers its remainder as a plain ERC-20 transfer to
  `remainderTo`, with no callback; `TokenDistributor` needs none.
- `expectedBalance` for the mainnet `TokenDistributor` is the requester's to set at that
  launch (75 % of the launch token's supply). It is deliberately a constructor argument
  and not a constant, because a constant that disagrees with the launch would brick
  `distribute()`.
- Vesting schedules start at the launch block's timestamp, for both modes; in deferred
  mode that is before the tokens arrive, which only shortens the schedule by the delay
  between deployment and delivery.
- Tokens sent to a Distributor after its shot is spent are unrecoverable; it has no owner
  and no sweep.
- Explorer verification of the four created contracts and the Sepolia broadcast itself
  belong to the deployer; this job deploys nothing. No Slither or Mythril run was
  available here; `forge build`, `forge test` (512 fuzz runs, plus the verifier's seed)
  and `forge fmt --check` ran.

### Verification

`forge build`, `forge test` (109 tests) and `forge fmt --check` pass with forge 1.8.3 and
solc 0.8.28, including with
`FOUNDRY_FUZZ_SEED=0xc9e37f2966eb091d147347f5fedf61f88601fc49a380710fea9dba293fe4aa3e`.
`forge script script/Distribute.s.sol:Distribute` with the five env vars set simulates to
completion without an RPC and reports the Distributor and the four addresses it created.
