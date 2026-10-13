# ECONOMY.md — e-Farm token economy (v1.0.3, frozen)

**Changelog.** v1.0.4 (2026-09-16), errata only: §9 gate 2's **earnings clause** is re-specified from ECU to **coin income** per farm-active-day. Coins are what farming pays, so automation that out-farms humans shows up there; ECU per farm-day measured only how fast a farm *converts* coins it had already earned — a cash-out rate, which the smart ring maximises by design while farming no better than anyone else. ECU per farm-day stays as a diagnostic; the freeze clause and the 1.2× multiple are unchanged. · v1.0.3 (2026-09-16), errata only: §9 gate 2 is re-specified as ECU **per farm-active-day**, ring against honest, because the old share-of-active ratio punished stricter enforcement (the old number survives as a diagnostic); and Town Hall **staking is ECU**, reversing v1.0.2 — governance is for token holders and the stake is a velocity sink (§11) — while the coin treasury that funds public orders stays coins, and gate 7 counts bonds + stake again. The stake is escrowed rather than banked, so the mayor cannot spend what voters are owed. · v1.0.2 (2026-09-16), errata only, no economy change: §3.0b now lists which flows are ECU and every ledger reason is mapped to that list (Town Hall *staking* is coins; only the prize treasury is ECU); §5.1 fence spread is burned in coins, not paid to the reserve, and the noise band is log-symmetric on [0.6, 1/0.6]; §5.2's daily Black Market cap is in coins (`daily_volume_cap_coins`); §12 a freeze sells the herd for coins that burn rather than moving ECU to the Bank pool; two numbers that existed twice are now single-sourced — the feed mixer is 800 coins (`capacity.capital_goods.mixer`) and butter is 10 litres a block (`animals.cow.litres_per_butter`, with `dairy.milk_per_butter` deleted); and fields now live on plots, so `village.free_plots_at_level_2` is the only free-plot key and the per-level plot limit is the only cap on sowing (§11.3). · v1.0.1 (2026-09-15), errata only, no economy change: §7 starter cash, loan and repayment in coins (repaid coins burned); §5.1 fence anchored at 0.95 × the Co-op price with a 2.5× hard cap (the round-2 decision); §3.0's stale cap-2 sentence removed.

**Status: frozen at v1.0 on 2026-09-14**, after simulation round 11. From here the spec
changes only by a versioned amendment, never an edit in place. v1.0 is the two-layer
economy of §3.0b — coins for play, ECU as the token, a tick-settled Exchange between
them — with the caps of §3.3, the Town Hall treasuries of §7 and the gates of §9. Sections
below that describe earlier designs are kept for the reasoning; where they conflict with
§3.0b, §3.3, §7 or §9, those sections win.

Working spec for the ECU economy. Game is English-only. Numbers marked `TBD` are
placeholders to be set by simulation (see §9). Everything else is a design decision.

v0.2 resolved the contradictions found in phase 0 (see `PLAN.md` §6): Co-op opening hours
(§3.4), the Farmers' Market fee split (§4, §3.5), the reserve-vs-burn rule (§3.5), the
level-2 condition (§7), vet pricing (§8), rabbit reproduction (§8), lot-stepped quoting
(§3.1, §5.1), the Black Market commit-reveal direction (§5.1), and risk scoring.

v0.3 folds in the demand-side addendum as **§11**, which replaces the flat withdrawal
toll with an aged-harvest toll (§1, §11.1), adds bonded capacity to the invariant
(§10, §11.2), adds scarce land and contests, and adds simulation gates 6-8 (§9). Risk
scoring moves from §11 to **§12** to make room; it is otherwise unchanged.

Guiding rule: **the game never mints ECU.** All ECU in play comes out of a treasury
and returns through sinks. Prices at the Co-op and Black Market are driven by
inventory (supply vs NPC demand) and reserve health — never by RNG alone.

---

## 1. Units, buckets, gates

- `ECU` — ERC-20 on Base, fixed supply 100,000,000, 1:1 with in-game ledger units.
- Ledger balances per farm are split into two buckets:
  - `deposited` — bridged in from chain. Always withdrawable (minus toll).
  - `earned` — from Co-op sales, market sales, prizes. Withdrawable only when
    `loan_outstanding == 0` (i.e. level ≥ 2).
- Spending order: `earned` first, then `deposited` (so speculators' own money is
  what they keep liquid).
- Withdrawal: **toll per §11.1** — an aged-harvest toll on `earned` (12 % at ≤ 7 days
  falling to 1 % at ≥ 60 days, lots consumed oldest-first) and a flat 1 % on `deposited`,
  all burned. On top of the toll: a 48 h delay and a daily cap
  `cap = max(500, 1.5 × EMA7(daily_revenue))`. The delay stretches to 7 days, and
  withdrawal can be blocked outright, at the risk-score thresholds in §12.

## 2. What the original did (recovered) and what broke

| Original rule (2004–2015) | Effect | Verdict |
|---|---|---|
| Start with 300 écus + 1,500 loan; need 2,000 to repay → level 2 | Debt-based onboarding | **Keep**, but the 300 is the *cash portion of* the 1,500 loan, not a separate grant (§7) |
| Co-op buys produce at fixed prices (rabbit 25, wool 8/cm, eggs fresh only) | Unbounded sink for player supply; no price signal | **Replace** with inventory pricing (§3) |
| Co-op sells supplies at fixed prices, limited by daily purchase count | Crude but effective rate limit | **Keep** the trip limit, float the prices |
| Purchase trips: L1 12/day, L2 18, van 36 (Co-op + Farmers' Market combined) | Anti-spam | **Keep**, extend (§6) |
| Farmers' Market: player listings, any price under a ceiling, 24/7 | Real P2P price discovery | **Keep**, add floor + wash-trade rules (§4) |
| Black Market: prices re-rolled every minute, wide swings, cheapest ~5 am, costs points | Fun, but refresh-spam/bot exploitable | **Redesign** as thin bonding curve + seeded noise (§5) |
| Reputation points: + for Farmers' Market trades and production, − for Black Market | Social throttle | **Keep**, make cluster-aware |
| Buy rabbits on Farmers' Market at ~8, sell to Co-op at 25 | Money printer | **Closed** by §3 no-arbitrage caps |

## 3. The Co-op (NPC market maker)

The Co-op holds an ECU **reserve** `R` and a virtual **inventory** `I_g` per good `g`.
It **buys produce** (eggs, milk, butter, wool, rabbits, poultry, crops) and **sells
supplies** (feed, water, soap, syringes, starter animals, equipment).

### 3.0 Round 9: the Co-op buys by daily pro-rata settlement

Supersedes §3.1 for what the Co-op **buys**, and cap 3 of §3.3. Farms deliver during
opening hours; nothing is paid on delivery. At the tick:

```
B       = R · ln2 / T_half                 T_half = 730 days, recomputed each tick
W       = Σ_g P_ref(g) · q_g               the day's deliveries, valued at P_ref
P(g)    = clamp( P_ref(g) · B / W , 0.2 · P_ref(g) , 1.25 · P_ref(g) )
```

Oversupply lowers every price in the same proportion; scarcity pays the 1.25 cap and the
unspent budget stays in the reserve. If the 0.2 floor binds, the Co-op accepts only the
volume B covers at the floor, pro-rata by farm, and returns the rest (perishables then
expire). The no-flip cost-basis rule still applies per unit.
The fence float top-up comes out of what the day's deliveries leave of B, so no reserve
outflow escapes the budget. Because payouts can never exceed `R · ln2 / T_half`, gate 1
(read as an exponential half-life) passes by construction and is kept as a regression
assertion. `f_inv` and `f_res` below now price only Co-op **sells** and anchor the fence.

**UI requirement.** During the day the Co-op screen shows the running estimate at
deliveries so far — "at current deliveries eggs pay ~1.08" — and says plainly that the
price is set at the tick.

### 3.0b Round 10: two layers — coins for play, ECU as the token

Supersedes §3.0 for the Co-op. **Coins** are the in-game play currency, minted and burned
by the Co-op; **ECU** is the token. Only the **Exchange** connects them.

- *Ledger.* Coins are a second unit in the same ledger, outside the 100 M: a coin purse per
  farm, a mint account that runs negative, and a burn account. A movement never mixes
  units, and the coin accounts sum to zero as their own invariant.
- *Coins.* The Co-op buys produce and sells supplies in coins at fixed prices (P_ref and
  `p_ref_sell` as written); the inventory curve survives only for the fence and as an
  optional ±25 % modulation. The Farmers' and Black Markets trade in coins. The loan, level
  thresholds, capital goods, upkeep and the vet are coins. Farmers' Market fees in coins
  are half burned and half paid to the Town Hall's coin treasury, which funds public orders
  (§7).
- *ECU, unchanged.* Land auctions, bonds, contests, champion auctions and the Bank's
  starter-kit purchases (which pay players ECU: terminal demand). Public orders moved to
  coins in round 11 (§7).
- *Which flows are ECU (v1.0.2).* The list is closed, and every ledger reason is mapped to
  it (`tests/ledger/test_reason_units.py`); anything not named here is coins.

  | ECU flow | What it covers |
  |---|---|
  | Bonds | Locking, releasing and forfeiting stake-to-expand bonds (§11.2) |
  | Land | Plot auctions: the burn, the reserve half, the Town Hall half (§11.3) |
  | The Exchange | The ECU paid out for tendered coins, and the ECU paid in to buy them |
  | The Vault | Deposits, withdrawals and their tolls, and the pool either side of it |
  | The Bank's kit purchases | Starter kits bought from players, and their market fee |
  | Prizes | Contests, champion auctions, the ECU prize treasury |
  | Governance | Vote stakes, escrowed for a term and returned at the election (§7) |
  | Freeze forfeits | A frozen farm's `earned` bucket, burned (§12) |

  Three ECU reasons are not game flows at all and could not be coins, because every
  account they touch is an ECU account: the **genesis allocation** (the supply itself,
  before anything has moved), **treasury rebalancing** (the Bank pool's surplus swept to
  the Co-op reserve), and the contracts-phase **revenue buyback** (§11.4).

  **Town Hall staking** (§7) is **ECU**, and is listed above under governance: voting is
  for token holders and the stake is a velocity sink, held in escrow for the term. Only
  the *public order* treasury is coins. **A freeze** sells the herd for coins that burn
  (§12); the simulator's old move of livestock value from the reserve to the Bank pool in
  ECU was the sim disagreeing with the game about which layer a freeze operates on.
- *The Exchange, settled at the tick.*

  ```
  B    = R · ln2 / 730 + EMA30(ECU paid in for coins)
  rate = min(B / coins tendered that day, r_max)   (ECU per coin; r_max = 1.0; coins burned)
  buy  = yesterday's rate × 1.10                   (ECU per coin bought; the ECU joins the reserve)
  ```

  What the ceiling leaves of B stays in the reserve: a thin tender day's windfall goes to
  nobody. Buying coins is open from day 1, with deposited ECU, at the capped launch rate
  until the first settlement; the coins→ECU direction still needs level 2. The Bank pays
  players for starter kits at coin price × EMA7(settled rate), capped at r_max, and buys
  from players only after the Exchange has settled 7 days — before that, kits come from
  the Co-op.

**Exchange emission is fixed and shared.** B is set by the reserve and by ECU flowing in
for coins — not by how many farms there are. Every tender that day divides the same B, so
**the ECU a farm earns per coin falls as the village grows**, even when no one does
anything wrong. Nothing inside the game compensates for that. The only variable that can
is the token's price: if a coin buys less ECU but ECU is worth more, a farm is no worse
off. That is a property of the design, not a defect to tune away, and it must be stated to
players in these terms.

The run-10 simulation (1,000 honest farms, 8 signups a day, seed 20260909) shows the
shape. B stays near 31,000 ECU a day while tendered coins grow with every farm that
reaches level 2:

| Day | Level-2 farms | Coins tendered | Rate (ECU/coin) |
|---|---|---|---|
| 51 | 57 | 259 | 1.000 (ceiling) |
| 61 | 255 | 11,498 | 1.000 (ceiling) |
| 66 | 281 | 59,039 | 0.707 |
| 91 | 338 | 86,605 | 0.420 |
| 121 | 498 | 142,785 | 0.230 |
| 151 | 594 | 174,271 | 0.181 |
| 176 | 666 | 195,036 | 0.158 |

**UI requirement.** The day's Exchange rate — the running estimate during the day, the
settled rate after the tick — and the coins tendered so far that day are always visible,
on every screen that offers a tender and on the Co-op screen.

**Supply prices are a gameplay knob, not an economy lever.** At the original supply prices
recurring supplies take 12–17 % of a farm's coin revenue, below the old 30–40 % band.
That share only changes how fast coins accumulate — coin inflation — and so how many coins
chase the fixed ECU emission. Raising the supply multiplier `m` slows pacing (farms reach
level 2 later) without changing B.

  A farm may tender at most the EMA7 of its own coin income (anti-bot), and only once its
  loan is repaid — that replaces the loan gate on earned ECU. The aged toll (§11.1) applies
  to ECU received from the Exchange.
- *Gates.* See §9 for the v1.0 list.
- *No cap 2* (round 11). The Co-op prints its coins, so a Farmers' Market cap has no
  reserve to protect, and the cost-basis no-flip rule already stops the
  buy-cheap-sell-to-the-Co-op round trip. Unfloored the cap had no fixed point above zero
  (milk's price index reached zero in round 9); floored, it priced milk. Cap 1 stays (§3.3).

### 3.1 Buy price (Co-op pays the farmer)

```
P_buy(g) = P_ref(g) · f_inv(g) · f_res
f_inv(g) = clamp( (I_target(g) / I_g)^γ , 0.25 , 1.25 )      γ = 0.6
f_res    = clamp( (R / R_target)^α ,          0.40 , 1.25 )   α = 0.5
```

- Selling `q` units adds `q` to `I_g` *before* pricing the next unit → large dumps walk
  down the curve. **Quoting is stepped in lots of 10**: each lot of 10 units is priced at
  the curve value for the inventory level at the *start* of that lot, then `I_g += 10`
  before the next lot is priced. A final partial lot is priced at its own lot price. This
  stepped form — not the continuous integral — is what the quote function implements and
  what the tests hand-compute. The same lot rule applies to the Black Market fence (§5.1).
- `I_target(g) = 3 · c_g · active_farms` (three days of demand). Inventory above target
  = "too many eggs" → price drops; below = scarcity → price rises.

**Adaptive demand.** `c_g` is not a fixed guess. It is an EMA of what players actually
sell the Co-op, per active farm per day, scaled by `κ` and floored at `c_min`:

```
c_g(t) = max( c_min , κ · EMA(sales of g per active farm per day) )
```

A good's first `fast_start_days` use a short half-life so a newly traded good finds its
level before the shelf fills; after that it steadies at the long one. The floor matters
because `I_target ∝ c_g`: without it a good nobody has sold lately has no target, no
defined `f_inv`, and nowhere for its shelf to drain to.

**Elastic removal.** NPC removal scales with how full the shelf is, hourly:

```
R_g = (c_g · active_farms / 24) · (I_g / I_target(g))^ρ        ρ = 1.0
```

Matching the drain to the flow — taking exactly the average of what players sell — has
**no restoring force**. Writing `S` for daily sales per farm, `N` for active farms and
`d` for any daily spoilage, flow-matching gives `S·N = κ·S·N + d·I`, which pins `I` at
`S·N(1−κ)/d`: for a perishable that is an arbitrary number unrelated to the target, and
for an imperishable (`d = 0`) there is no solution at all — the shelf empties at `κ ≥ 1`
and grows without bound below it.

With elastic removal the shelf is its own feedback. At steady state inflow equals removal:

```
S·N = c_g·N·(I / I_target)^ρ  ,  and at rest c_g = κ·S  with κ = 1
⇒   (I / I_target)^ρ = 1   ⇒   I = I_target
```

for every good, perishable or not, with no per-good tuning. Away from rest it is a true
controller: a week of sales at 2× settles the shelf towards `2 · I_target` — six days of
stock, `f_inv = 2^(−0.6) ≈ 0.66` — and a week at 0.5× towards 1.5 days, pulling `f_inv`
up to its ceiling. Removal is stepped hourly against the day's inflow rather than applied
as one daily lump: removal compounds against the stock it removes from, so a day's sales
dropped in at midnight and drained for 24 hours settle near 2.5 days rather than 3.

**Spoilage** is no longer a second dynamic. Removal moves no ECU — the goods were bought
and paid for when the Co-op took them in — so what happens to them afterwards is a label,
not a force. `spoilage_share(g)` is the part of `R_g` reported as spoiled rather than
eaten, for eggs and milk; it does not act on the inventory.
- `R_target` = 35 % of supply at launch, re-based quarterly by Town Hall vote (§7).

### 3.2 Sell price (Co-op sells supplies)

```
P_sell(g) = P_ref_sell(g) · clamp( (S_target(g) / S_g)^γ , 0.80 , 3.00 )
```

`S_g` = stock, restocked hourly at rate `r_g · active_farms / 24`. Speculators who
drain feed stock push the price up; the arbitrage self-extinguishes.

### 3.3 No-arbitrage caps (hard constraints, checked on every quote)

v1.0 (the two-layer economy of §3.0b):

1. For any good the Co-op both buys and sells: `P_buy(g) ≤ 0.70 · P_sell(g)`.
2. *Removed in round 11.* The Farmers' Market VWAP cap (`P_buy ≤ 0.90 · VWAP`). The Co-op
   pays in coins it prints; the cost-basis no-flip rule on bought units is sufficient.
3. *Superseded by the Exchange.* The Co-op's 2 %-of-R payout budget and 10 % reserve floor
   protected ECU the Co-op no longer pays out. The reserve's only outflow is the Exchange,
   bounded by `B = R · ln2 / 730 + EMA30(coin-purchase ECU)` and the rate ceiling (§3.0b).

### 3.4 Opening hours and trips

Keep the **original** rhythm exactly (MECHANICS §7, §12.8), server time:

| | Open |
|---|---|
| Weekdays | 05:00–14:00, 17:00–20:00, 22:00–03:00 |
| Weekends | 09:00–14:00, 19:00–03:00 |

The daily tick window is **03:00–05:00**, which the weekday and weekend schedules both
already leave closed. Each Co-op purchase consumes one trip (§6). Sales to the Co-op do
not consume trips; the price curve is the throttle.

### 3.5 Reserve accounting

Every ECU a player spends is either a **reserve inflow** or a **burn**, never both, and the
split is by what is bought:

- **Consumables and services → Co-op reserve.** Feed, water, soap, syringes, seeds,
  fertiliser, fuel, starter animals, the vet subscription, express delivery.
- **Capital goods → 100 % burned.** Pens and hutches, barn expansions, the well, van,
  truck, harvester, feed mixer, cheese machine, silos, cold room, technician repairs.

Rationale: recurring spend recycles into the reserve so the Co-op can keep buying produce;
one-off capacity purchases leave the economy for good, which is what makes capacity a real
sink rather than a transfer.

Inflows (v1.0.2): ECU paid in to buy coins, the Bank's kit purchases from Co-op supply, and
the reserve's half of a land sale. The Black Market fence spread and liquidated collateral
are **coins** and burn — neither reaches the reserve — and Farmers' Market fees do **not**
flow here either (§4). Outflow: the Exchange, and nothing else. Consumables and services
are still the recycling side of the split above, but they are now paid in coins that burn,
which is why the reserve's own ECU inflow is so much narrower than it was in §3.0.
`reserve_ratio = R / R_target` is published live on the home page ("the Co-op rate").

## 4. Farmers' Market (P2P, reputation +)

Limit-order book per good, 24/7.

- Taker fee 2.5 %: 50 % burned, 50 % to Town Hall treasury. That is the whole fee — the
  Co-op reserve takes no share of it (§3.5). No listing fee.
- **Price band** per good, recomputed hourly:
  `floor = 0.50 · P_buy_coop(g)`, `ceiling = 2.0 · P_sell_coop(g)` (or `3.0 · P_buy_coop`
  if the Co-op doesn't sell `g`). Orders outside the band are rejected. This kills
  wash trades at absurd prices and laundering between sybil farms.
- Each **buy** consumes one trip. Listing is free of trips.
- **New-farm buy lock**: a farm may list from day 0 but may not *buy* until server day 2,
  or until its first sale to the Co-op, whichever comes first. Without this the starter
  cash (§7) is spendable the minute a sybil farm exists, and a ring's established farm can
  list at the band ceiling and collect it. Requiring a Co-op sale means the farm has
  produced something first.
- Orders expire after 48 h; eggs after 24 h (they keep ageing while listed).
- Self-trade blocked. Trades between farms in the same risk cluster (shared Privy user,
  device, IP/ASN, or funding wallet) execute but award 0 reputation and raise both
  farms' risk score by 10.
- Reputation: +1 commerce point per trade side, capped at 50 points/day per farm.
- Wash-trade detector: same pair, ≥ 3 round-trips in 24 h → 0 points, risk +20.

## 5. Black Market (NPC fence + anonymous board, reputation −)

Keep the thrill (volatile, cheap at dawn, ruinous if you refresh at the wrong minute)
but make it order-flow-driven and unpredictable rather than a free RNG.

### 5.1 Fence prices

```
P_bm_buy(g)  = 0.95 · P_buy_coop(g) · noise(t) · clamp( (J_target(g) / J_g)^2 , 0.20 , 3.00 )
P_bm_sell(g) = 1.30 · P_bm_buy(g)
```

- `J_g` = fence inventory, thin: `J_target(g) = 0.25 · I_target(g)`. Exponent 2 → dumping
  100 eggs crashes the quote; scarcity spikes it. Quoting steps in **lots of 10**, exactly
  as at the Co-op (§3.1), final partial lot at its own lot price.
- `noise(t)` is **log-symmetric on [0.6, 1/0.6]** — so its *geometric* mean is exactly 1 —
  updated every minute from a **backwards** hash chain (commit-reveal):
  - pick a random seed `x_1440`, compute `x_i = H(x_{i+1})` down to `x_0`;
  - publish `x_0` at the start of the hour as the commitment;
  - at minute `i`, reveal `x_i` and derive `noise` from it;
  - anyone verifies `H(x_i) == x_{i-1}`.

  The chain must be built backwards and consumed forwards, so the published commitment
  reveals nothing about future minutes. (Generating forward *from* a published root would
  let anyone holding it compute every future quote.) The hour's chain is stored encrypted
  at rest. If the server misses a minute, that minute's noise is the last revealed value.
  Same quote for everyone in that minute; nobody, including us, can front-run it. Part of
  the swing is a predictable **daily cycle** (trough at dawn, peak in the evening) and the
  rest is per-minute noise; the cycle lives in the exponent, so it moves *when* the good
  minutes fall without moving the average (the "get up at 5 am" trick survives). The old
  arithmetic band of 0.6–1.6 had a mean of 1.1 and paid a 10 % premium to anyone trading at
  random, which is the opposite of what gate 4 asks for: blind trading must lose and only
  timing should pay.
- The anchor is the Co-op's price today, not `P_ref`: the timing game is played on a
  spread against the venue the player could otherwise sell into (round 2).
- Hard cap: `P_bm_buy(g) ≤ 2.5 · P_buy_coop(g)`. The fence **mints the coins it pays and
  burns the coins it is paid** (v1.0.2), so the spread is burned rather than paid to the
  Co-op reserve and the fence holds no float of its own.

### 5.2 Rules

- 5 % fee on every trade, 100 % burned.
- Each trade consumes **two** trips.
- Raid risk: every trade has `p_raid = 3 %` of confiscation (goods or coins lost, burned).
  Expected value is negative for blind trading, positive for timed trading.
- Reputation −2 per trade; farms with negative weekly reputation lose Town Hall vote weight.
- Anonymous board (P2P): band is wide, `0.2×`–`3×` fence price, same 5 % burn,
  cluster trades blocked outright (this is the laundering venue, so no exceptions).
- Daily Black Market volume cap per farm: `L1 500 · L2 2,000 · L3 5,000` **coins**
  (`black_market.daily_volume_cap_coins`, renamed in v1.0.2 — the venue has traded in coins
  since round 10 and the ECU name was left behind).
- Gifts/collectibles sell only here, capped at 300 ECU each (original rule).

## 6. Trips (purchase rate limit)

**Round 9:** a trip is consumed only when a trade executes. Walking up to an empty book,
or to a fence that will not fill, costs nothing.

| Level / transport | Trips per day |
|---|---|
| Level 1 (on foot) | 12 |
| Level 2 (no vehicle) | 18 |
| Van (2,000 ECU, level 2) | 36 |
| Truck (TBD, level 3) | 60 |

Trips reset at the daily tick. Co-op purchase = 1, Farmers' Market buy = 1,
Black Market trade = 2. Trips are the primary anti-spam and anti-bot throttle and
make bot scaling linear in *farms*, which the sybil system handles.

## 7. Bank and Town Hall

**Round 9 additions.**

- *Starter kits are bought, not conjured.* For each signup the Bank pool buys the kit
  (8 kits, 3 hens, 1 rooster, 1 calf) from players on the Farmers' Market at up to
  1.2 × VWAP; Co-op supply is the fallback when the market cannot fill (MECHANICS §3.3's
  "rested cows seed new L1 players", generalised).
- *Bank pool sweep.* The pool's floor is its genesis allocation (15 M). At the tick only
  what sits above the floor — recycled repayment surplus — sweeps to the Co-op reserve;
  the launch runway never does. If the pool still falls below 30 days of signup outgoings
  it is reported as a warning series (`bank_pool_days_cover`), with no automatic top-up.
- *Public orders* (round 11: coins). The Town Hall has two treasuries. The **coin
  treasury** is 50 % of every Farmers' Market fee; the mayor spends it down to a 10 % float
  each term on produce orders at 1.1 × VWAP for public works (school, hospital, leisure,
  police), players' listings fill them for coins, and the goods are consumed. The **ECU
  treasury** is 50 % of land proceeds (which no longer go to the reserve) and pays prizes.

- **Bank**: 1,500-coin starter loan, collateral = the farm's animals, 0 interest. Like
  every level threshold, the loan is in coins (§3.0b). It is **part cash, part in-kind**:
  on signup **300 coins** are minted into the farm's coin purse (`LOAN_DISBURSE`), and the
  remaining **1,200** is the starter animals, for which nothing moves. No ECU moves at
  signup. `loan_outstanding` is the full 1,500 from day 0.

  The starter cash is deliberately a loan, not a grant. A flat grant per signup is a
  sybil faucet: a ring mints farms, and its level-2 farm lists at the Farmers' Market band
  ceiling to collect the grants. Making the cash a loan liability means a sybil farm
  starts 1,500 in debt rather than 300 up.

  **Repayment is only permitted when the farm holds ≥ 2,000 coins**: the farm repays
  1,500 — the repaid coins are burned — and keeps a ≥ 500 buffer. This is the original's
  "hold 2,000 écus" objective expressed as a precondition on repayment rather than a
  second, separate gate. Level 2 is granted at the moment of repayment, so
  `loan_outstanding == 0 ⇔ level ≥ 2` holds exactly, and the Exchange's coins→ECU
  direction (§3.0b) opens on it. Farm idle 30 days with `loan_outstanding > 0` → animals
  sold to the Co-op for coins, applied to the loan, remainder burned.
- **Town Hall**: stake **ECU** to vote for the mayor (locked one 30-day term = velocity
  sink). Governance belongs to token holders, and the stake is **escrowed, not banked** —
  it sits in its own account, never in the treasury the mayor spends, because a stake the
  mayor could spend would be a fee by another name. It counts toward §9 gate 7's locked
  figure alongside bonds. Treasury = 50 % of Farmers' Market fees, in **coins**, which is
  a separate thing from the stake. Mayor spends on weekly prizes and
  public works. Mayor can propose `R_target`, `c_g`, `γ`, `α` changes within ±20 %/term;
  larger changes need a two-term vote.

## 8. Production reference (from the original, level 1–2)

Use as the base tuning; the economy above sits on top of these yields.

- Start: 3 hens + 1 rooster; 8 baby rabbits (random sex); 1 cow; 300 ECU cash — the cash
  portion of the 1,500 loan (§7), with the animals as the other 1,200.
- **Rabbits**: each fertile couple produces **one kit per day with probability
  `repro_rate`**, where `repro_rate = 0.40 base (wheat) + 0.10 water + 0.25 carrots
  + 0.25 salad`, capped at 1.0. There are no 0–2 litters. A couple is one adult male and
  one adult female in the same pen; a male can serve up to 3 females.
  Sanity check against the veteran number: 18 couples on wheat + water + carrots gives
  `repro_rate = 0.75` → 13.5 kits/day ≈ the "18 couples ≈ 14 babies/day" rule of thumb.
  Level 1 hutch cap 50. Level 2 hutch rule: 3 baby hutches : 2 adult : 1 empty buffer for
  the daily sale. Hutch build 600 ECU/2 d or 400 ECU/3 d.
- **Poultry**: 1 rooster per 5 hens for laying; 1 egg/hen/day; eggs spoil after 1 day
  (sell or incubate); incubate coops with ≥ 4–5 eggs. Level 1 cap 50 hens + 10 roosters.
  Layers need no water; brooders and chicks do.
- **Cow**: milk daily (adult at 10 days / 80 kg); wash before 18:00 or no evening milk;
  12 L milk → 1 butter (level 2).
- **Sheep** (level 2): adult at 8 days / 30 kg; wool 2 cm/day, +1 cm with salad, stops at
  20 cm; Co-op reference 8 ECU/cm.
- **Feed recipe**: 1 wheat + 1 corn + 1 water + 1 butter + 1 carrot crate → 8 basic feed
  bags (sellable). One bag feeds a whole mini-coop / mini-hutch.
- **Level 2 costs**: well 500 ECU (6 buckets/day), van 2,000, harvester 2,500,
  storage +15 slots 2,000/5 d or 1,500/7 d, corn field 100 (+50 fertiliser),
  vet subscription 0.5 ECU per sick head per day (§12.1 of MECHANICS; there is no
  30 ECU/day flat variant).
- Advice inherited from veterans: don't move to level 2 before ~10,000 ECU.

## 9. Parameters (initial) and simulation plan

| Param | Value | Notes |
|---|---|---|
| Supply | 100 M ECU | 15 % DEX pool (factory-owned single-sided V4 position), 10 % swarm, 50 % vault (35 % Co-op reserve + 15 % Bank pool), 15 % team (12 m cliff / 36 m), 5 % community (12 m linear), 5 % listings |
| `γ` (Co-op inventory exponent) | 0.6 | Black Market uses 2.0 |
| `α` (reserve exponent) | 0.5 | |
| Exchange budget (v1.0) | `B = R · ln2 / 730 + EMA30(coin-purchase ECU)`, rate ≤ 1.0 ECU/coin | §3.0b; replaces the 2 %-of-R Co-op payout budget |
| Fees | FM 2.5 % (½ burn, ½ Town Hall coin treasury), BM 5 % (burn), withdraw aged 12 % → 1 % (burn), pool buy 0.5 % USDC, pool sell 1.5 % burn | §7, §11.1, §11.6 |
| `p_raid` | 3 % | |
| `P_ref` | rabbit 25, wool 8/cm, egg 1.2, milk 2, butter 28, corn 4 (coins) | fixed coin prices; a mature level-1 farm grosses ~130 coins/day in run 10 |

Before launch, run an agent-based sim (1,000 honest farms, 200 bot farms, 50 arbitrageurs)
over 180 simulated days and require:

The v1.0 gates:

1. Reserve ≥ 0.5 of `R_target` at day 180, and a projected **exponential** half-life
   (`ln2 · R / net outflow`, last 30 days) ≥ 730 days. Holds by construction — the Exchange
   can never pay more than B — and is kept as a regression assertion.
2. **Ring coin income per ring-farm-active-day ≤ 1.2 × honest coin income per
   honest-farm-active-day**, **and** ≥ 50 % of ring farms frozen (first freeze) before
   day 90. A ring farm, while alive, may out-farm no honest one; the freeze clause is the
   defence. Days after a farm's freeze count for neither the numerator nor the
   denominator. Measured against the smart ring (variant B, below); the lockstep ring
   (variant A) is kept as a regression. **v1.0.4:** the earnings clause is measured in
   **coins**, not ECU. Coins are what farming pays — the Co-op, the Farmers' Market and
   the Black Market all settle produce in coins — so a ring that automates the game into
   out-producing humans shows up there. ECU per farm-day, v1.0.3's clause, measures how
   fast a farm *converts* coins it has already earned; the smart ring plays the honest
   routine and then tenders every coin its cap allows, so it read 1.54× on a cash-out
   rate while farming no better than anyone else. **v1.0.3:** per-farm-day replaced
   "share of Exchange ECU ≤ 1.2 × share of active farms", which punished stricter
   enforcement — freezing the ring removed its farms from the active count faster than
   the ECU they had already earned, so the ratio *rose* as the defence improved. Both
   older numbers — ECU per farm-day, and the share of active — are still reported as
   diagnostics.
3. Farmers'-Market-to-Co-op arbitrage profit per trip < 1 coin.
4. Black Market blind-trading EV < 0; timed-trading EV > 0 (in coins).
5. *Diagnostic, not yet scored:* ECU into the reserve (coin purchases, the Bank's kit
   purchases from Co-op supply) ≥ 30 % of Exchange outflow over any rolling 60 days.
6. Over any rolling 7 days, net ECU withdrawn ≤ 15 % of the ECU side of DEX liquidity.
7. By day 180, `bonded` + Town Hall stake ≥ 20 % of circulating ECU (circulating =
   everything outside the reserve, the Bank pool, LP, vesting and burned; coins excluded).
   Both halves are ECU locked out of circulation and unspendable while locked: a capacity
   bond (§11.2) and a vote stake (§7), the latter escrowed for the term.
8. The aged toll and the risk freeze together capture ≥ 25 % of the Exchange ECU the ring
   receives before day 30.

**The smart ring (variant B).** 200 farms in 20 clusters of 10, each cluster paying out to
its own wallet, with jittered human-like timing and residential connections. It plays
honestly until level 2, then tenders every coin its cap allows and withdraws every ECU.
Only the shared-destination signal and in-cluster trades can see it.

**The impatient cohort — an assumption.** 15 % of honest farms are given a $20 USDC
budget (yaml) and spend it on coins — ECU bought on the pool, deposited, then exchanged —
when they cannot afford an expansion. Every reserve-inflow figure that includes it is only
as large as those two numbers make it, and is reported that way.

## 10. Invariants (assert in tests)

- `sum(all ledger balances) + R + bank_pool + burned == 100 M` at all times. The sum
  includes every per-farm `bonded` account (§11.2).
- A bond can only move to its own farm on release, or to the Bank pool on liquidation.
  There is no other exit from a `bonded` account.
- `P_buy(g) ≤ 0.70 · P_sell(g)` for every quoted good.
- No farm's `earned` bucket is withdrawn while `loan_outstanding > 0`.
- Co-op daily payouts ≤ 2 % of R.
- A Black Market quote is identical for all farms within the same minute.

---

## 11. Demand side

Under §1–§10 the only way ECU reaches a player is a Co-op payout. That makes farming the
sole source of supply to players and the DEX the natural destination, so the token trades
like an egg-backed stablecoin with structural sell pressure. This section adds reasons to
hold ECU and sources of demand that do not come from farming. **None of them pay yield
from a treasury.**

All numbers here are yaml keys; those marked TBD are set by the simulator.

### 11.1 Aged-harvest withdrawal toll (replaces the flat 1 % in §1)

- The `earned` bucket is kept as **dated lots** (earning day, amount). Withdrawals consume
  lots oldest-first.
- Toll on each lot depends on its age at withdrawal:
  `toll(age) = 12 %` for age ≤ 7 days, falling linearly to `1 %` at age ≥ 60 days.
- `deposited` bucket: flat 1 % (unchanged). All tolls are burned.
- The 48 h delay and the daily cap from §1 still apply on top.
- The UI shows the blended toll before confirmation ("withdraw 2,000 now: 6.4 % toll; in
  12 days: 3.1 %").

### 11.2 Stake-to-expand bonds

Capacity has a **base tier** (bought and burned, as in MECHANICS §12.2) and **bonded
tiers** above it that require ECU *locked*, not spent.

| Expansion | Base tier (burned) | Beyond base: bond per unit (locked) |
|---|---|---|
| Fields | 2 fields | 5,000 per extra field (TBD) |
| Adult coops / hutches | 4 units each | 2,000 per extra unit (TBD) |
| Cow shed | 3 cows | 3,000 per extra cow (TBD) |
| L3 common barn | — | 20,000 per barn (TBD) |
| L3 silo / tank / cold room | 1 each | 4,000 per extra (TBD) |

- Bonds live in a per-farm ledger account `bonded`: counted in the 100 M invariant,
  not spendable, not withdrawable, earning nothing.
- Downsizing releases the bond after a 30-day cooldown (`BOND_RELEASE`).
- A frozen farm (risk ≥ 90, §12) forfeits its bonds to the Bank pool on liquidation.

### 11.3 Scarce land

- The world is made of **villages** of 1,000 plots. A village opens when the previous one
  has more than 800 active farms.
- Every farm gets 2 free field plots at level 2. Any further field, apiary or L3 building
  needs a plot. Maximum 3 owned plots per farm at L2, 6 at L3.
- The Town Hall sells plots by **Dutch auction**: start at 10× the last clearing price
  (floor 1,000 ECU), decaying linearly to the floor over 48 h; first bidder wins; proceeds
  burned (`LAND_AUCTION_BURN`). One auction per day per village while unsold plots remain.
- Plots are transferable on the Farmers' Market (the 2.5 % fee rule applies) and become
  ERC-721 in the contracts phase. Plot ownership is what makes land a demand source:
  newcomers who want more than two fields must buy ECU.

### 11.4 Revenue buyback (policy, not guarantee)

- 50 % of net fiat revenue (cosmetics, merch, sponsorships, ad-free) buys ECU on the DEX
  every week, spread across the week (TWAP), from a public wallet.
- Bought ECU: 50 % burned (`BUYBACK_BURN`), 50 % to the Co-op reserve (`BUYBACK_IN`).
- Public dashboard: euros in, ECU bought, ECU burned, reserve delta.
- Never described as a floor or a promise; wording reviewed by counsel before launch.
- Cosmetics never affect production, capacity, trips or prices (this keeps MECHANICS §11).

### 11.5 Contests

- **Weekly Egg League** (later Milk, Wool and Rabbit leagues): entry 50 ECU, 30 % burned,
  70 % to the prize pool, top 10 split 30/20/12/10/8/6/5/4/3/2 %. Cluster-linked farms
  (§12) cannot occupy more than one paid place.
- **Livestock market champion auctions** (Wed/Sun): rested animals with lineage sold to
  the highest bid in ECU; 5 % of the hammer price burned, the rest to the seller.
- **Seasonal events** (Easter, Harvest, Christmas): entry-fee contests, same split.
- No price-prediction or betting products of any kind.
- Reason codes: `CONTEST_ENTRY_BURN`, `CONTEST_ENTRY_POOL`, `CONTEST_PRIZE`,
  `AUCTION_HAMMER_BURN`.

### 11.6 Fees at the pool, never in the token

- ECU is a plain ERC-20: no transfer hook, no fee-on-transfer, no pair whitelist, no
  owner-adjustable tax. This is a hard requirement for listings and scanners.
- DEX liquidity is a Uniswap V4 pool with a fee hook: buys pay 0.5 % taken in USDC to the
  buyback wallet; sells pay 1.5 % taken in ECU and burned. Parameters immutable after
  deployment.
- The treasury provides at least 50 % of initial liquidity (from the 15 % LP allocation)
  and keeps its share of the standard swap fee.

### 11.7 Where each allocation sits at launch

The §9 split says how the 100 M is divided. This says where each slice physically is on
day one, which is what determines what can move and what cannot.

| Slice | Share | Where it sits | Liquid? |
|---|---|---|---|
| DEX pool | 15 % | The Uniswap V4 pool (§11.6), a single-sided position owned by the launch factory | Yes — this is the only ECU anyone can buy |
| Swarm | 10 % | The launch's contributor allocation, paid out by the launch | Per the launch's own schedule |
| Co-op reserve | 35 % | Vault contract, mirrored in the ledger | Game-side only |
| Bank pool | 15 % | Vault contract, mirrored in the ledger | Game-side only |
| Team | 15 % | `TeamVesting`: 36-month linear schedule, nothing before a 12-month cliff | No |
| Community | 5 % | `CommunityVesting`: 12-month linear schedule, no cliff | No |
| Listings | 5 % | Multisig | Held, not liquidity |

The token is created by the launch, which places the pool and the swarm slices itself and
sends the remaining 75 % to the `Distributor` contract. `distribute()` then splits that
75 % in one transaction: 50/75 to the Vault, 15/75 to team vesting, 5/75 to community
vesting and the remainder to listings, so no dust is stranded and no wallet ever holds the
supply in between. There is no separate LP lock: the pool position is custodied by the
factory, which replaces the two-year lock earlier drafts of this table specified.

### How the ledger models it

Three pots, all accounts under the 100 M invariant, and four flows between them:

```
    buy       pool_ecu -> wallet          (0.5 % USDC fee to the buyback wallet)
    deposit   wallet   -> farm.deposited  (the Vault takes custody)
    withdraw  farm     -> wallet          (aged toll burned, §11.1)
    sell      wallet   -> pool_ecu        (1.5 % of the ECU burned)
```

- `pool_ecu` — the ECU side of the pool. Opens at the 15 % pool allocation, held as a
  factory-owned single-sided V4 position.
- `wallet` — ECU players hold on chain, between the pool and the Vault.
- The **Vault is a rollup, not a fourth balance.** Every game-side token is already an
  account — the farm buckets, the reserve, the Bank pool, the escrows — so a `vault`
  account holding the same ECU beside them would count the supply twice and turn 100 M
  into 200 M. What the Vault contract custodies is the sum of those accounts, and a
  deposit moves exactly that figure: wallet down, Vault up, one balanced transaction.

The USDC side of the pool is not ECU and is not a ledger account. It lives on the pool's
own row, which is what keeps it out of a sum that means "all the ECU there is".

Two consequences worth stating plainly:

- **The circulating float at launch is the 15 % in the pool.** Everything else is either
  vesting, held, game-side, or the swarm's allocation on the launch's schedule. The team
  slice releases nothing for twelve months and the community slice releases one 365th a
  day, so day one adds about 685 ECU of community vesting to the float and no team tokens.
  A player who wants to bridge ECU in buys it on the pool first, which is why the
  simulator's vault stand-in is funded from the pool slice and not from listings —
  listings is a multisig balance, not liquidity.
- **The reserve and the Bank pool are custodied by the Vault contract but spent by the
  game.** The ledger is the authority on their balances; the contract is the authority on
  the tokens. The two are the same 50 % viewed from either side, and reconciling them is
  a phase-2 job.

Gate 6 measures net withdrawals against the *pool's* ECU side, not against the whole
50 % in the Vault: what matters is whether a week of exits can be absorbed by the only
place they can actually be sold.

### 11.8 Implementation order

§11.1 and §11.2 belong to the withdrawals and buildings modules already planned. §11.3
and §11.5 are a new module `village/`, after module 7. §11.4 and §11.6 are contracts-phase
and ops, stubbed in the simulator only.

---

## 12. Risk scoring and sybil defence

Every farm carries a `risk_score` in **0–100**. It is the mechanism ECONOMY §9 gate 2 refers
to when it says risk scoring "freezes" a bot ring.

### 11.1 Thresholds

| Score | State | Effect |
|---|---|---|
| ≥ 40 | **shadow** | Co-op payout ×0.7; withdrawal delay 7 days instead of 48 h |
| ≥ 70 | **challenge** | Withdrawals blocked; Co-op payout ×0.5; must pass a challenge to clear (phase 2 — stubbed as a manual flag for now) |
| ≥ 90 | **frozen** | All market actions and withdrawals blocked, and the score does not decay: freezing is terminal. After 7 days frozen the animals are sold at `P_buy` for **coins that burn**, the farm's own coins burn, its `earned` bucket is burned and its bonds are forfeited to the Bank pool (v1.0.2) |

The farm is told its state, never its score or which signal fired.

### 11.2 Signals

Additive, and decaying by **−5/day** while the farm is quiet (no signal fires):

| Signal | Points |
|---|---|
| Shared withdrawal destination or funding source with another farm | +30 |
| Timestamp entropy below threshold (machine-regular action timing) | +25 |
| Action sequence identical to another farm on ≥ 5 days | +25 |
| Datacenter ASN | +20 |
| Farmers' Market wash round-trips (§4 detector) | +20 |

The simulator implements the first three; the other two need request metadata that does not
exist off-chain in phase 1. Thresholds and point values are all `economy.yaml` keys and are
expected to move once the sim runs.

In both liquidations the animals are sold at `P_buy`, and since v1.0.2 both are paid in
**coins the Co-op mints and immediately burns** — the farm never holds them, so there is
nothing to spend between the sale and the burn, and no ECU moves at all. What differs is
what the coins are applied to. A defaulted starter loan (§7) clears the outstanding balance
and burns the remainder; whatever the animals do not fetch is written off, because the loan
is coins and there is no pool to reimburse. A frozen farm burns the lot, burns its own
coins and its `earned` bucket, and forfeits its bonds to the Bank pool — it is an
enforcement action, not a credit event, so there is nothing to return. **Bond forfeits are
the only ECU a freeze produces**, and the only ECU that still reaches the Bank pool.
