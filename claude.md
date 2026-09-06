# CLAUDE.md — Denver Bulldogs AFL Grand Final App

## 1. What this is

A single-night web app for the Denver Bulldogs ARFC AFL Grand Final watch party.

**Event:** Friday 25 September 2026, ~10:30pm–1:30am MDT, 1111 Lincoln St, Denver CO. Roughly 50–80 people in a pub, most of them drinking, all of them on phones, watching a match that starts at 2:30pm AEST Saturday 26 September at the MCG.

The app has two halves, and the hierarchy between them is the most important design fact in this document:

1. **The Squares board — the main event.** The club sells 100 squares at $25 each (or 5 for $100) through Zeffy. Squares are randomly assigned before first bounce. Real prize money, held and paid by the club. The app's job is to display this well: live score, your squares highlighted, and the winning square lighting up at each siren.

2. **The Kennel — the bonus game.** A free virtual-currency prediction game running in the gaps between sirens. Currency is **Bones**. Prizes are non-monetary (novelty belt, bragging rights). Its purpose is to make the night more fun and to give people a reason to buy squares.

If you ever have to choose between these, the Squares board wins. It must work. The Kennel is allowed to be cut.

**Tagline:** Put your Bones where your mouth is.

---

## 2. Hard constraints — never violate these

These are not preferences. If a task appears to require breaking one, stop and ask.

1. **The app never touches money.** No Stripe, no payment SDK, no card fields, no checkout, no price calculation. All money flows through Zeffy, externally. Where the UI needs to prompt a purchase, it renders an outbound link to the Zeffy page and nothing more.
2. **Bones have no cash value.** They cannot be bought, sold, transferred between players, or redeemed. No UI copy may imply otherwise.
3. **All Kennel prizes are non-monetary.** Never render copy like "winnings", "cash out", "odds", or "bookmaker". Acceptable vocabulary: Bones, back, pool, payout, ladder, Top Dog.
4. **All balance and pool mutations happen server-side.** The client submits an intent ("stake 50 on option X"); the server validates, mutates, and returns truth. The client never computes or writes a balance.
5. **The server clock is authoritative** for market open/lock times. Never trust a client timestamp.
6. **Settlement is idempotent.** Running it twice must not double-pay. Guard on `settled_at`.
7. **No live sports data integration.** No AFL API, no scraping, no Champion Data. All scores and stats are entered by the host. This is deliberate.

---

## 3. Glossary

| Term | Meaning |
|---|---|
| **Bones** | Virtual currency. No cash value. |
| **Courtesy Bones** | Flat grant every guest receives on joining (default 1,000). |
| **Bonus Bones** | Extra grant for square-holders, per square, capped at 5 squares (default 250 each). |
| **The Kennel** | The prediction game as a whole. |
| **Market** | One prediction with two or more options. |
| **Pool** | Total Bones staked on one option of a market. |
| **Top Dog** | Overall Kennel winner at full time, by cumulative net profit. |
| **The Bark** | An obnoxious celebration animation fired at an opponent. Costs Bones. Phase 4. |
| **Host** | Harry. Runs the console all night. Single operator. |

---

## 4. Build order and gates

Nineteen days. Build in this order. **Do not start a phase until the previous one is merged and demoed.**

**Phase 0 — Discovery. No code edits.**
Read the existing repo (if any), confirm the stack, confirm backend access works, and produce a written implementation plan covering schema, API surface, and open questions. Stop and wait for approval.

**Phase 1 — Squares board + host score entry + projector view.** *Must ship.*
This alone makes the night better than last year. Everything after this is upside.

**Phase 2 — Bones, Next Goal markets, ladder.**
The core Kennel loop.

**Phase 3 — Studs v Spuds, Futures.**

**Phase 4 — Barks, streaks, polish.** Cut without hesitation.

Gate condition for every phase: demoed end-to-end on a phone, merged to main, deployed to the live URL.

---

## 5. Backend

Postgres-backed. Schema below is written for Postgres. Realtime subscriptions are needed on: market status changes, pool totals, live score, ladder.

Use database-level constraints wherever a rule can be expressed as one. The `UNIQUE (market_id, player_id)` constraint on `bets` is load-bearing — it is what makes hedging impossible.

### Tables

**players**
```
id              uuid pk
nickname        text not null            -- unique, case-insensitive
session_token   text not null            -- opaque, stored client-side
claim_email     text                     -- optional, used to match Zeffy purchase
balance         int not null default 0   -- materialised; mutated only inside ledger transactions
squares_count   int not null default 0
is_square_holder boolean not null default false
created_at      timestamptz
```

**squares_purchases** — imported from Zeffy CSV
```
id, purchaser_name, purchaser_email, squares_count, linked_player_id (nullable)
```

**grid_config** — single row
```
row_digits int[10]   -- digit assigned to each row (home team last digit)
col_digits int[10]   -- digit assigned to each column (away team last digit)
home_team  text
away_team  text
```

**squares**
```
id            int pk (1..100)
row_index     int (0-9)
col_index     int (0-9)
purchase_id   uuid nullable
```

**score_events**
```
id, quarter int, team ('home'|'away'), score_type ('goal'|'behind'),
home_points int, away_points int,          -- running totals AFTER this event
created_at, voided boolean default false
```
Running totals are stored per event so that undo is a soft delete plus recompute, not arithmetic in someone's head.

**quarter_results**
```
quarter int pk, home_points, away_points, winning_square_id, settled_at
```

**markets**
```
id               uuid pk
type             ('next_goal'|'studs_v_spuds'|'futures_winner'|'futures_norm_smith')
quarter          int nullable
title            text
status           ('draft'|'open'|'locked'|'settled'|'void')
opens_at, locks_at, settled_at
winning_option_id uuid nullable
max_stake        int nullable
counts_toward_quarter_prize boolean not null default true
sponsor_label    text nullable        -- e.g. "The Ironbark Round"
```

**market_options**
```
id uuid pk, market_id, label text, pool_bones int not null default 0, sort_order int
```

**bets**
```
id uuid pk
market_id, option_id, player_id
stake     int not null
payout    int nullable
profit    int nullable
settled_at timestamptz nullable
UNIQUE (market_id, player_id)
```

**ledger** — append-only audit trail
```
id, player_id, kind ('courtesy_grant'|'square_bonus'|'stake'|'payout'|'refund'|'bark'),
amount int (signed), market_id nullable, balance_after int, created_at
```

---

## 6. The rules that must be exactly right

### 6.1 One bet per player per market

Enforced by the unique constraint. A player picks one option and one stake. While the market is `open` they may **increase** their stake but **never change their option**.

This exists because Bones only enter the ladder once deployed. Without it, a player could stake equally on both sides of a market, get roughly their money back, and bank ladder credit for free.

### 6.2 The ladder is net profit, not balance

This is the definition that makes the game about picking well rather than clicking often.

```
profit(bet) = payout - stake
```

- Backed the winner: `profit = floor(stake × losing_pool / winning_pool)`
- Backed a loser: `profit = -stake`
- Market voided: `profit = 0`

**Quarter ladder** = sum of profit over markets settled in that quarter where `counts_toward_quarter_prize = true`. **Resets every quarter.** Top three at each siren take a prize.

**Top Dog** = sum of profit over all settled markets, including futures. One winner at full time.

Because the ladder is profit and not balance, un-staked Bones are worth exactly zero. The anti-hoarding rule is satisfied by the definition itself — no separate logic needed.

Futures markets have `counts_toward_quarter_prize = false`, so a bet placed at 10:30pm cannot decide the Q4 prize.

### 6.3 Parimutuel settlement

For market M with winning option W:

```
P_win  = sum of stakes on W
P_lose = sum of stakes on all other options

if P_win = 0:                     VOID — refund every stake, profit 0 for all
if P_lose = 0:                    every backer of W gets stake back, profit 0

otherwise, for each bet b on W:
    payout = b.stake + floor(b.stake × P_lose / P_win)
    profit = payout - b.stake

for each bet b not on W:
    payout = 0
    profit = -b.stake
```

Dust from flooring is discarded and logged. Never distribute more than `P_lose`.

**Worked example (this is the canonical test case):**
> Winning pool 500 Bones. Losing pool 1,000 Bones. My stake 50.
> My share of the winning pool is 50/500 = 10%.
> Payout = 50 + floor(0.10 × 1000) = 50 + 100 = **150**. Profit = **100**.

**Write unit tests for this function before writing any UI.** Cover: normal case, zero winning pool, zero losing pool, single bettor, dust remainder, and a settle-twice idempotency check.

### 6.4 Market state machine

```
draft → open → locked → settled
                     ↘  void
open   → void
locked → void
```

Transitions are host-only. Bets are accepted **only** when `status = 'open'` AND `now() < locks_at`, both evaluated on the server.

Placing a bet is one transaction: verify market open, verify balance ≥ stake, verify no existing bet on a different option, verify stake ≤ `max_stake` if set, insert or increment bet, decrement balance, increment `pool_bones`, append ledger row. All or nothing.

---

## 7. Market types

### Next Goal — settles every few minutes
Two options: home team or away team. "Which team scores the next goal?"

The host's score entry drives this automatically:

- **Host taps GOAL for a team:**
  1. Append score event, update running totals.
  2. If a `next_goal` market is `open` or `locked`, settle it with that team as winner.
  3. Create and open a new `next_goal` market, `locks_at = now() + 90s`.
- **Host taps BEHIND:** append score event only. The squares board updates. The next-goal market is untouched.

One host action drives the squares board and the market cycle together. The betting window lands in the gap between a goal and the next centre bounce, which is exactly when phones should be out.

### Studs v Spuds — settles each quarter
A pre-selected pair of players, most disposals in that quarter. Four matchups configured before the night, one per quarter, editable from the console.

Opens at the start of the quarter, locks five minutes in.

At each siren the host enters **cumulative game-to-date disposals** for both players. The server computes the quarter delta by subtracting the previous entry. The host never does arithmetic at 1am, and a mistyped number can be corrected without corrupting earlier quarters.

Equal disposals → void, refund all.

### Futures — settles at full time
Two markets, both opening pre-bounce and locking at first bounce:
- **Match winner** — two options.
- **Norm Smith Medal** — a pre-selected candidate list plus an "Any other player" option, so a surprise winner doesn't void the market.

Both carry a `max_stake` (default 200) so an early punt can't run away with Top Dog.

---

## 8. Screens

### Punter — mobile web, no install, no password

**Join:** QR or short code → enter nickname → optionally enter the email used on Zeffy to claim squares and bonus Bones. Session token in `localStorage`. If the email doesn't match, they still play with courtesy Bones and can ask the host to link them manually.

**Squares (default tab).** Live score header. The full grid with the player's squares highlighted. The current live digits highlighted so it's obvious who is in front right now. A banner when the player is live on the current score.

**Kennel.** Open markets, each with a live pool-split bar showing how the room is leaning. Stake buttons: 25 / 50 / 100 / Max. Current position and balance.

The pool split is a real feature, not decoration. Seeing a market 80% loaded on one side is what pulls people onto the short side and prevents lopsided dud payouts.

**Ladder.** Current quarter ladder, plus Top Dog standings.

### Host console — `/host`, PIN protected
Built first. It is the single point of failure.

- Four large score buttons: Home Goal / Home Behind / Away Goal / Away Behind. **With undo.** Mis-taps at 1am are guaranteed.
- Market list with open / lock / settle / void.
- Studs v Spuds disposal entry.
- End-of-quarter control: shows the winning square, closes and awards the quarter ladder.
- Manual player↔purchase linking.
- Global pause switch that freezes betting without breaking the app.

Must work on both phone and laptop.

### Projector — `/screen`, no auth, read-only
Designed to be legible from across a pub. Large score and squares grid, the current market with its live pool split, top five on the quarter ladder, and recent Barks. Auto-reconnecting realtime; never requires a manual refresh.

---

## 9. Failure modes to design for

- **Pub wifi dies.** Show a clear offline banner. Reconnect and reconcile against server state on return. Never let a queued client action double-submit.
- **The app dies entirely.** The host has a printed squares grid as backup. Provide a print-friendly `/host/print` route.
- **Host mis-taps a score.** Undo on every score action.
- **A market can't be resolved.** Void refunds every stake cleanly.
- **Nobody backed the winner.** Void and refund, per §6.3.
- **Load.** Include a seed script that generates 60 fake players placing random bets, so the whole thing can be load-tested before the night.

---

## 10. Human tasks — Harry, not the agent

- [ ] Export the Zeffy purchaser CSV, run the random square assignment, import
- [ ] Choose the four Studs v Spuds matchups after the teams are known
- [ ] Choose the Norm Smith candidate list
- [ ] Set sponsor labels (Ironbark round, the pub's round)
- [ ] Print the backup squares grid
- [ ] Test pub wifi and the projector setup in advance
- [ ] Recruit someone for quarter-break disposal lookups
- [ ] Get a local read on Colorado charitable gaming before promoting the Kennel
- [ ] Rehearse the console end-to-end at least once

---

## 11. Working agreement

- Phase 0 is discovery only. No edits until the plan is approved.
- Branch per phase, PR into main. No direct commits to main.
- Ask before adding any dependency.
- Write the settlement function and its tests before any Kennel UI.
- If a request seems to need payment handling or a live sports feed, stop and ask. It doesn't.
- Optimise for reliability on one specific night, not for scale, extensibility, or reuse. This app runs for three hours and then never again.