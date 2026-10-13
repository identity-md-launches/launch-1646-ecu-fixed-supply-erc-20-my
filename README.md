# e-Farm contracts

Five contracts ship in phase 1: the **ECU** token, the **FarmVault** that custodies the
game-side half of the supply, the **Distributor** that creates the other four and splits
the launch allocation, and the **TeamVesting** and **CommunityVesting** wallets. One
creation deploys all of them: the launch manifest lists only `Distributor`, whose
constructor creates the token, the vault and both vesting wallets and performs the split
in the same transaction. Everything else the game does — farms, plots, animals, markets,
the Bank — is off-chain, and `docs/ECONOMY.md` is the authority on it.

The guiding constraint, from ECONOMY.md §1: *the chain holds the token and the custody,
the ledger holds the economy.* A contract here should be boring enough that an auditor can
read it in one sitting, because the interesting rules are all in the Python.

## Layout

```
src/ECU.sol                 fixed-supply ERC-20, no owner, no hooks
src/FarmVault.sol           deposits in, operator-signed vouchers out, capped per voucher and per day
src/DistributorBase.sol     the launch root: creates vault + vesting (+ token), splits per §11.7
src/Distributor.sol         the root in token-creating mode: the one contract the manifest lists
src/TokenDistributor.sol    the root for an existing token (mainnet custom_token launch), deferred split
src/TeamVesting.sol         OZ VestingWalletCliff: 36 months, 12-month cliff, renounce disabled
src/CommunityVesting.sol    OZ VestingWallet: 12 months linear, renounce disabled
src/interfaces/             phase-2 shapes only (plots ERC-721, animals ERC-1155)
script/Distribute.s.sol     the Sepolia dry run: new Distributor(...) and nothing else
test/                       forge tests for all of the above
ADAPTATION.md               what changed for the launch, and which audit finding required it
```

## Setup

Dependencies are git submodules, so a fresh clone needs:

```bash
git submodule update --init --recursive
cd contracts
forge build
forge test
```

## The contracts

### ECU

A plain ERC-20 with `ERC20Burnable` and nothing else. 100 000 000 tokens, 18 decimals,
minted once in the constructor to the distributor.

Three deliberate absences, each of which an exchange or a scanner checks for:

- **No mint function.** The supply is fixed by construction, not by a renounced role, so
  there is no owner to compromise and no timelock to trust. "Ownership renounced after
  distribution" is satisfied here by never having an owner at all.
- **No transfer hook, no fee, no blacklist.** A token that takes a cut on transfer is
  indistinguishable from a honeypot to automated review. The 1.5 % sell fee of §11.6 lives
  in the pool hook, not in the token.
- **No pause.** Custody can be paused (below); the token cannot.

`burn` is kept because two spec'd flows destroy ECU: the §11.4 buyback and the §11.6 sell
fee. Both burn tokens the burner already holds.

### FarmVault

Custody for the 50 % that the game spends: the Co-op reserve and the Bank pool. §11.7
calls the Vault "a rollup, not a fourth balance" — the ledger decides how that 50 %
divides between farms, reserves and escrows, and the contract deliberately knows nothing
about any of it.

**In:** `deposit(amount)` pulls an approved amount and emits `Deposited`. Deposits are
never paused — stopping the exit must not trap the entrance.

**Out:** `withdraw(to, amount, nonce, expiry, signature)`, where the signature is an
EIP-712 `WithdrawalVoucher` from the operator key. Anyone may submit the transaction; the
signature is the authority and the tokens can only go to the `to` the operator named. The
nonce is per-recipient and sequential, and is spent before the transfer.

Note there are **two different signatures** in a withdrawal, and conflating them is the
easiest mistake to make here:

| | Signed by | Proves | Verified by |
|---|---|---|---|
| `Withdraw(farmId, amountMicros, nonce, deadline)` | the player's wallet | intent | the backend (`app/api/signing.py`) |
| `WithdrawalVoucher(to, amount, nonce, expiry)` | the operator key | authorisation | this contract |

They share the EIP-712 domain (`e-Farm`, version `1`) and nothing else. The game applies
the aged-harvest toll, the daily cap, the 48-hour delay and the risk state (§11.1, §12)
between the two — which is exactly why the chain cannot be the authority on withdrawals.

**Bounded:** the operator is a hot key, so the chain does not trust it with the whole
custody at once. Three limits are checked before anything moves:

| Limit | Set by | Initial value (script) |
|---|---|---|
| `maxVoucherAmount` — the most one voucher may carry | constructor, then the guardian | `INITIAL_MAX_VOUCHER_AMOUNT` = 50 000 ECU |
| `maxOutflowPerWindow` — the most that may leave in one 24-hour window | constructor, then the guardian | `INITIAL_MAX_OUTFLOW_PER_WINDOW` = 250 000 ECU |
| `MAX_VOUCHER_LIFETIME` — the furthest ahead an expiry may lie when submitted | constant | 7 days |

The window opens on the first withdrawal after the previous window closed, so at most two
windows' worth can leave in any 24 hours and never more than one cap inside a window. The
initial values are named constants in `script/Distribute.s.sol`: the window cap is about
7.5× the §3.3 Exchange budget at launch and a week of it stays under gate 6 of §9.

**Pausing** covers withdrawals only, and only the guardian may do it. The guardian is one
address in the contract and a 2-of-3 Safe in practice: keeping the threshold in the Safe
means the signing policy can change without redeploying custody. The guardian can also
rotate the operator with `setOperator`, which bumps the **operator epoch** bound into
every voucher: everything signed before the rotation is dead and stays dead even if the
same key is installed again later. Handing the guardian role over is **two-step** —
`setGuardian(next)` nominates, `acceptGuardian()` from the nominee completes it — so a
mistyped address cannot strand pause and rotation. `bumpNonce(to)`, callable by the
guardian or the operator, voids one recipient's next unspent voucher without pausing
anyone else.

**Trust assumptions** (also in the contract's NatSpec): the guardian can appoint any
operator instantly and so has custody up to the caps, which it can also raise — a guardian
hand-over is a custody hand-over, and the guardian must be a Safe; the operator must be an
EOA, because vouchers are verified with ECDSA only and there is no ERC-1271 path; the
guardian can pause withdrawals indefinitely while deposits keep flowing.

### Distributor

The launch allocation never passes through a wallet, and the launch never has to order
anything: `ECU(distributor)` mints to the Distributor, `FarmVault(ecu, …)` fixes the token,
and the Distributor fixes the vault — a cycle that separate transactions can only resolve
by predicting nonces, which a bytecode manifest cannot do. So the Distributor is the
**root**: its constructor creates the other contracts itself, in one transaction, and
nothing is left to wire afterwards.

`Distributor(operator, guardian, teamBeneficiary, communityBeneficiary, listings,
maxOutflowPerWindow, maxVoucherAmount)` — token-creating mode, the one the manifest lists:

1. `new ECU(address(this))` — the whole 100 M is minted to the Distributor;
2. `new FarmVault(ecu, operator, guardian, maxOutflowPerWindow, maxVoucherAmount)`;
3. `new TeamVesting(teamBeneficiary, block.timestamp)` (36 months, 12-month cliff) and
   `new CommunityVesting(communityBeneficiary, block.timestamp)` (12 months), both with
   `renounceOwnership` disabled;
4. emits `Launched(token, vault, teamVesting, communityVesting, listings)`;
5. splits the supply and emits `Distributed`; the Distributor ends with a zero balance.

| Share of what arrives | Where |
|---|---|
| 50/75 | the Vault |
| 15/75 | `TeamVesting` |
| 5/75 | `CommunityVesting` |
| the remainder (5/75 plus rounding dust) | listings |

The created addresses are public immutables — `token()`, `vault()`, `teamVesting()`,
`communityVesting()` — next to `listings()`. There is no owner and no `distribute()` call
to make: in this mode `distribute()` reverts `AlreadyDistributed`. The constructor takes
seven static arguments and calls no pre-existing contract, so the launch's empty-chain
rehearsal runs it as is. Tokens sent to the Distributor *after* launch are unrecoverable
(no owner, shot spent); it is not an address to send anything to.

`TokenDistributor(token, expectedBalance, operator, guardian, teamBeneficiary,
communityBeneficiary, listings, maxOutflowPerWindow, maxVoucherAmount)` — the second
mode, for the mainnet custom_token launch, where IMD creates the token, places 15 % in the
pool and 10 % with the swarm and sends the remaining 75 % to this contract as
`remainderTo`. The constructor skips token creation, never calls the token (it may not
exist yet), creates the vault against it and the two vesting wallets, and emits
`Launched`. The split is deferred to a **permissionless one-shot `distribute()`** that
refuses with `InsufficientBalance(held, expected)` until the contract holds at least
`expectedBalance`, and then splits everything it holds (over-delivery included) by the
same table. A refused call does not consume the shot. `expectedBalance` must equal what the
launch will deliver — 75 % of the token's supply — because a larger value leaves
`distribute()` refusing forever and a smaller one lets a partial delivery spend the shot.

### Vesting wallets

Thin wrappers over OpenZeppelin 5.7 with the schedule fixed in code:

| Wallet | Base | Schedule |
|---|---|---|
| `TeamVesting` | `VestingWalletCliff` | 36 months linear, nothing before a 12-month cliff |
| `CommunityVesting` | `VestingWallet` | 12 months linear, no cliff |

The beneficiary is the wallet's owner and may `transferOwnership` (a Safe migrating to a
new Safe) but `renounceOwnership` reverts: a renounced VestingWallet pays `address(0)` and
would strand the slice. In production both beneficiaries are Safes.

## Launch distribution and the Sepolia dry run

The deployment is one creation. The launch manifest lists `Distributor` with its seven
constructor arguments; `script/Distribute.s.sol` does the same thing by hand for the
Sepolia dry run — `run()` reads the five addresses from the environment and `deploy()`
broadcasts `new Distributor(...)`. There is no ordering, no nonce prediction and no
`distribute()` call; the script holds no supply and never reads `address(this)`.

| Constructor argument | Dry run (Sepolia) | Mainnet |
|---|---|---|
| `operator` | the owner wallet | the backend's EOA hot key |
| `guardian` | the owner wallet | a 2-of-3 Safe |
| `teamBeneficiary` | the owner wallet | a Safe (transferable owner, never renounceable) |
| `communityBeneficiary` | the owner wallet | a Safe |
| `listings` | the owner wallet | the listings multisig |
| `maxOutflowPerWindow` | 250 000 ECU (`INITIAL_MAX_OUTFLOW_PER_WINDOW`) | guardian may change after launch |
| `maxVoucherAmount` | 50 000 ECU (`INITIAL_MAX_VOUCHER_AMOUNT`) | guardian may change after launch |

The two caps are the values the brief left open; they are named constants in the script
(the window cap is about 7.5× the §3.3 Exchange budget at launch and a week of it stays
under gate 6 of §9) and the guardian can change both at any time with
`setMaxOutflowPerWindow` / `setMaxVoucherAmount`. The vesting schedules start at the
block timestamp of the launch transaction.

The script reads every address from the environment with no default, on purpose:
`VAULT_OPERATOR`, `VAULT_GUARDIAN`, `TEAM_BENEFICIARY`, `COMMUNITY_BENEFICIARY`,
`LISTINGS_MULTISIG`. For the testnet dry run the owner wallet fills all five, so after
the transaction the owner wallet holds the 5/75 listings slice directly and owns both
vesting wallets, while the vault's keys are the owner wallet too. (`.env.example` still
lists `LIQUIDITY_ADDRESS`, which nothing reads any more; it is outside this job's
writable paths.)

| Slice | Share | Where |
|---|---|---|
| DEX pool | 15 % | factory-owned single-sided V4 position (mainnet launch; not in the dry run) |
| Swarm | 10 % | the launch's contributor allocation (mainnet launch; not in the dry run) |
| Co-op reserve + Bank pool | 50 % | the Vault, as one balance |
| Team | 15 % | `TeamVesting`, 12-month cliff / 36 months |
| Community | 5 % | `CommunityVesting`, 12 months linear |
| Listings | 5 % | multisig |

```bash
export COMMUNITY_BENEFICIARY=0x… TEAM_BENEFICIARY=0x… LISTINGS_MULTISIG=0x… \
       VAULT_OPERATOR=0x… VAULT_GUARDIAN=0x…
forge script script/Distribute.s.sol:Distribute \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

Verification on the explorer covers the Distributor; the four contracts it created are
verified separately by address (`forge verify-contract` with the constructor arguments
printed by the script's `Launched` event or its log lines).

Run it on Sepolia (11155111) first and let the backend run a full deposit → tick →
voucher → withdraw cycle against it before mainnet is considered. On mainnet the token
comes from the custom_token launch, and the root is `TokenDistributor` with that token as
`token` and the launch's remainder (75 % of supply) as `expectedBalance`, deployed before
the launch so its address can be given as `remainderTo`; after the launch has delivered,
anyone calls `distribute()` once.

### After launch: who does what

- **Guardian** (the owner wallet on the dry run, a Safe on mainnet): can pause and unpause
  withdrawals, rotate the operator (`setOperator`, which invalidates every outstanding
  voucher), raise or lower both caps, nominate a successor (`setGuardian` +
  `acceptGuardian` from the nominee) and bump a recipient's nonce. The guardian has
  custody up to the caps: a guardian hand-over is a custody hand-over.
- **Operator** (the backend's hot key): signs `WithdrawalVoucher`s including the current
  `operatorEpoch`; may bump a recipient's nonce. Must be an EOA.
- **Vesting beneficiaries**: call `release(token)` on their wallet when they want vested
  ECU; may `transferOwnership` to a new Safe; cannot renounce.
- **Listings multisig**: holds the 5 % float; nothing is required of it.
- **Nobody** owns the Distributor, the token, or can mint, pause or sweep anything else.
  Tokens sent to the Distributor after launch are stuck; it is not a deposit address.

## Phase 2

`src/interfaces/` holds `IFarmPlots` (ERC-721) and `IFarmAnimals` (ERC-1155) as interfaces
only, with the rules any implementation has to carry across written into them: granted
plots are untradable, the per-level ownership cap survives a transfer, and an animal that
is collateral, brooding or the last breeding male of its pen cannot be sold out from under
the game. Tokenising living, obligation-bearing assets is harder than tokenising a
collection, which is why it is not in phase 1.
