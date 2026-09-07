# Phase 2 — Bones, Next Goal Markets, and the Ladder

## Document purpose

This is the implementation handoff for Phase 2 of The Kennel. It is intended to be sufficient for a fresh engineering thread to begin work without reconstructing decisions from conversation history.

Phase 2 adds the core Kennel loop while preserving the Squares board as the primary, must-not-break experience:

1. Every guest receives free virtual currency called Bones.
2. Square-holders receive a capped Bones bonus.
3. Guests back one side of a short-lived Next Goal market.
4. A host-entered goal settles that market and opens the next one.
5. Net profit, rather than balance or turnover, determines the quarter ladder and Top Dog standings.

This document does not authorize Phase 3 or Phase 4 work.

---

## 1. Current baseline

### Product state

Phase 1 provides:

- A mobile-first punter experience with the Squares board as the default view.
- Nickname-based guest sessions stored locally on the guest's device.
- Optional Zeffy email matching and host-assisted purchase linking.
- A PIN-protected host console with score entry, undo, quarter controls, pause, team/digit setup, and purchase linking.
- A read-only projector screen.
- A print-friendly backup grid.
- Server-authoritative score state and idempotent host mutations.
- Realtime refresh when a browser-safe InsForge realtime client is configured, with polling as the key-free fallback.
- Unit, component, end-to-end, and backend integration verification.

### Stack

- React, TypeScript, and Vite.
- Vitest and Testing Library for unit/component tests.
- Playwright for browser flows.
- InsForge Postgres, edge functions, and hosting.
- One public edge-function entry point: `kennel-api`.
- Database access is behind `SECURITY DEFINER` RPCs; app tables are not directly writable by browser roles.

### Production services

- InsForge project: **The Kennel**.
- API base: `https://bk8ptwjs.us-west.insforge.app`.
- Edge function: `https://bk8ptwjs.function2.insforge.app/kennel-api`.
- Credentials remain in `.env.local`, `.insforge/project.json`, or InsForge secrets. Never copy them into source control or this document.

### Important local-development note

`index.html` is a Vite entry shell, not a standalone website. Opening it with a `file://` URL is not a supported run mode. Use `npm run dev`, a production build served over HTTP, or the hosted site.

---

## 2. Non-negotiable constraints

These rules apply to every schema, API, interface, test fixture, and line of copy:

1. The app never receives, calculates, stores, or transfers money. Zeffy remains an outbound link and CSV import source only.
2. Bones have no cash value and cannot be purchased, sold, transferred, or redeemed.
3. Prizes are non-monetary. Avoid gambling and cash terminology such as “cash out”, “bookmaker”, “odds”, or monetary “winnings”. Use Bones, back, pool, payout, ladder, and Top Dog.
4. All balances, pools, grants, bets, refunds, payouts, and reversals are computed and committed server-side.
5. The server clock decides whether a market is open or locked. Client timestamps are display-only.
6. Every settlement and externally retriable mutation is idempotent.
7. Score entry remains manual. Do not add an AFL feed, scraper, or live-sports API.
8. The Squares board remains the default punter tab and the visual priority on the projector.
9. Phase 2 may be removed without impairing Squares, score entry, quarter settlement, printing, or projector score display.
10. Do not add a dependency without explicit approval.

---

## 3. Phase 2 scope

### Included

- A 1,000-Bone courtesy grant for every guest.
- A 250-Bone bonus per linked square, capped at five squares/1,250 Bones.
- An append-only Bones ledger.
- Next Goal markets with home and away options.
- One selection per player per market; increasing the same selection is allowed while open.
- Stake controls for 25, 50, 100, and Max.
- Live pool split and current player position.
- Automatic Next Goal settlement when the host records a goal.
- No market change when the host records a behind.
- Host lock, settle, and void recovery controls.
- Refunds for void markets and markets with no winning backers.
- Quarter net-profit ladder and overall Top Dog ladder.
- Punter, host, and projector UI additions.
- Offline/reconnect behavior and idempotency protection.
- A development-only load generator for 60 synthetic guests.
- Full automated and manual verification.

### Explicitly excluded

- Studs v Spuds.
- Match-winner futures.
- Norm Smith futures.
- Barks.
- Streaks, achievements, or social animations.
- Bones transfers.
- Any payment integration.
- Any sports data integration.
- Native-app installation or password accounts.

The schema may reserve safe enum/check values for later market types, but no Phase 3 or Phase 4 behavior should be exposed in this phase.

---

## 4. Delivery and isolation model

1. Start from the latest verified `main`.
2. Create code branch `codex/phase-2-kennel`.
3. Create InsForge schema-only backend branch `phase-2-kennel` and switch the local project to it.
4. Keep all Phase 2 migrations, functions, test data, and previews on those branches until the phase is approved.
5. Open a draft pull request early enough that the implementation and migration are reviewable together.
6. Deploy the edge function and site preview against the backend branch.
7. Demo the full phone, host, and projector story.
8. Run a backend merge dry run and inspect the generated SQL before touching production.
9. Only after approval: merge the backend branch, redeploy the production function, merge the pull request, and deploy the live site.
10. Verify the live URL before declaring Phase 2 complete.

No direct commit to `main` and no direct Phase 2 schema change against production.

---

## 5. Database design

The existing `players.balance` remains the materialized balance for fast reads. The ledger is the audit trail and source for reconciliation; clients never write either.

### 5.1 Extend `players`

Add:

```text
courtesy_granted_at    timestamptz nullable
bonus_squares_granted  int not null default 0 check 0..5
```

Purpose:

- `courtesy_granted_at` makes the one-time 1,000-Bone grant explicit and idempotent.
- `bonus_squares_granted` records how many capped squares have already generated bonus Bones.
- Linking additional purchases grants only the positive difference up to five.
- Unlinking a purchase does not claw back a previously issued promotional grant. This avoids negative balances and punishing a guest for a host correction.

The migration must safely grant existing players their missing courtesy and square bonuses in one transaction and create matching ledger rows.

### 5.2 `markets`

```text
id                              uuid primary key
sequence                        bigint generated identity unique
type                            text not null
quarter                         int nullable check 1..4
title                           text not null
status                          text not null
opens_at                        timestamptz nullable
locks_at                        timestamptz nullable
settled_at                      timestamptz nullable
winning_option_id               uuid nullable
max_stake                       int nullable check > 0
counts_toward_quarter_prize     boolean not null default true
sponsor_label                   text nullable
settlement_winning_pool_bones   int nullable check >= 0
settlement_losing_pool_bones    int nullable check >= 0
settlement_dust_bones           int nullable check >= 0
created_at                      timestamptz not null default now()
updated_at                      timestamptz not null default now()
```

Constraints:

- `type` permits `next_goal`, `studs_v_spuds`, `futures_winner`, and `futures_norm_smith`; only `next_goal` is created in Phase 2.
- `status` permits `draft`, `open`, `locked`, `settled`, and `void`.
- A settled market requires `settled_at` and `winning_option_id`.
- A void market requires `settled_at` and no winner.
- An open market requires `opens_at` and `locks_at`, with `locks_at > opens_at`.
- Settlement pool and dust fields are immutable audit values after settlement.
- Add a partial unique index so there is at most one active Next Goal market for the current event (`draft`, `open`, or `locked`).

### 5.3 `market_options`

```text
id           uuid primary key
market_id    uuid not null references markets
option_key   text not null
label        text not null
pool_bones   int not null default 0 check >= 0
sort_order   int not null
created_at   timestamptz not null default now()
```

Constraints:

- Unique `(market_id, option_key)`.
- Unique `(market_id, id)` to support a composite foreign key from bets.
- A Next Goal market has exactly `home` and `away` option keys, created by the server in one transaction.
- `pool_bones` is updated only in the bet transaction and is checked during reconciliation tests against `SUM(bets.stake)`.

### 5.4 `bets`

```text
id           uuid primary key
market_id    uuid not null
option_id    uuid not null
player_id    uuid not null references players
stake        int not null check > 0
payout       int nullable check >= 0
profit       int nullable
settled_at   timestamptz nullable
created_at   timestamptz not null default now()
updated_at   timestamptz not null default now()
```

Constraints:

- Load-bearing unique constraint: `UNIQUE (market_id, player_id)`.
- Composite foreign key `(market_id, option_id)` references `market_options(market_id, id)` so an option from another market cannot be submitted.
- Unsettled bets have null payout/profit/settled time.
- Settled bets have non-null payout/profit/settled time.
- Voided bets use `payout = stake` and `profit = 0`.

### 5.5 `ledger`

```text
id               uuid primary key
player_id        uuid not null references players
kind             text not null
amount           int not null check amount <> 0
market_id        uuid nullable references markets
request_id       uuid nullable
reversal_of_id   uuid nullable unique references ledger
balance_after    int not null check >= 0
created_at       timestamptz not null default now()
```

Allowed kinds remain:

- `courtesy_grant`
- `square_bonus`
- `stake`
- `payout`
- `refund`
- `bark` (reserved for Phase 4; unused in Phase 2)

Reversals are new rows with the same `kind`, the exact negative amount, and `reversal_of_id` pointing to the original row. This preserves the approved vocabulary, makes goal undo auditable, and keeps the ledger append-only.

Add a trigger that rejects `UPDATE` and `DELETE` on ledger rows. Revoke browser-role writes on every new table and expose data only through server-authoritative snapshot functions.

### 5.6 Extend `score_events`

Add:

```text
settled_market_id  uuid nullable references markets
opened_market_id   uuid nullable references markets
```

These links make automatic goal settlement reversible by the existing “undo latest score” action without guessing which market cycle belonged to the score.

### 5.7 Indexes

At minimum:

- `markets(status, type, sequence desc)`.
- `markets(quarter, settled_at)` for ladders.
- `market_options(market_id, sort_order)`.
- `bets(market_id, option_id)`.
- `bets(player_id, settled_at desc)`.
- `ledger(player_id, created_at desc)`.
- `ledger(market_id, created_at)` where market is not null.

### 5.8 Security

- Enable RLS on all new tables.
- Explicitly revoke client insert/update/delete access.
- Browser clients call only `kennel-api`.
- The edge function calls narrowly scoped database RPCs.
- Continue storing only hashes of guest and host session tokens in Postgres.
- Do not expose the InsForge admin key in a `VITE_*` variable.
- The public site can call the public edge-function URL directly and poll. Realtime may be enabled only with a credential confirmed to be browser-safe.

---

## 6. Bones grant behavior

Create a server helper such as `kennel_apply_player_grants(player_id)` that locks the player row and:

1. If `courtesy_granted_at` is null, adds 1,000 to balance, appends a `courtesy_grant` ledger row, and stamps the grant time.
2. Computes `eligible_squares = LEAST(squares_count, 5)`.
3. Computes `new_bonus_squares = eligible_squares - bonus_squares_granted`.
4. If positive, adds `new_bonus_squares × 250`, appends one `square_bonus` ledger row, and advances `bonus_squares_granted`.
5. Returns without mutation when both grants are already satisfied.

Call it:

- During join, after automatic email matching and square recalculation.
- After a host links or unlinks a purchase and square counts are recalculated.
- From the migration/backfill for any Phase 1 players.

Required outcomes:

- A guest with no squares starts at 1,000.
- One linked square starts at 1,250.
- Five or more linked squares starts at 2,250.
- Retrying join does not grant twice.
- Re-linking the same purchase does not grant twice.
- Moving from two to four eligible squares grants exactly 500 more.
- Moving from six to seven squares grants nothing more.

---

## 7. Betting transaction

Implement a single server RPC, called by one edge-function action, for placing or increasing a bet.

Suggested signature:

```text
kennel_place_bet(
  player_token_hash,
  market_id,
  option_id,
  stake_delta,
  request_id
) -> player snapshot
```

Inside one database transaction:

1. Resolve and lock the guest by token hash.
2. Return the stored response if the request ID already has a `place_bet` receipt for this guest.
3. Lock the market and submitted option.
4. Require database status `open` and server `now() < locks_at`.
5. Require the game not to be globally paused.
6. Require a positive integer stake delta.
7. Require the option to belong to the market.
8. Lock any existing `(market_id, player_id)` bet.
9. If a bet exists, require the same option. Never allow switching or hedging.
10. Require `existing stake + stake delta <= max_stake` when a cap is present.
11. Require `player.balance >= stake_delta`.
12. Insert the bet or increment its stake.
13. Decrement the player's balance by exactly the delta.
14. Increment that option's `pool_bones` by exactly the delta.
15. Append a negative `stake` ledger row with the resulting balance.
16. Increment game/state version if needed for snapshot invalidation.
17. Store the response in `mutation_receipts`.
18. Emit `bet_updated`, `market_updated`, and `ladder_updated` only as appropriate.

The client sends an intent only. It must never predict a new balance or pool as truth.

“Max” means the smaller of current balance and remaining market cap. The UI may calculate a suggested button value for convenience, but the server repeats every check and returns authoritative state.

---

## 8. Next Goal lifecycle

### Opening

- Starting Q1 creates and opens the first Next Goal market if no active one exists.
- Starting Q2–Q4 does the same after the previous quarter's active market has been resolved or voided.
- The server creates the market and both team options atomically.
- Default lock time is `now() + interval '90 seconds'`.
- Labels are copied from current event team names.

### Effective locking

- The database clock is authoritative.
- A bet is rejected when `now() >= locks_at`, even if a stale client still shows an open button.
- Snapshots return an effective locked state when the stored status is `open` but server time has passed `locks_at`.
- The UI derives its countdown from the snapshot's `serverNow`, not the device's absolute clock.
- When a goal or host action next touches an expired open market, the transaction records the `open -> locked` transition before settlement/void.

This avoids requiring a timer job to preserve correctness. Polling/realtime is a display concern; the database check is the authority.

### Host records a behind

- Append the score event and update the Squares board.
- Do not alter, settle, extend, or replace the Next Goal market.

### Host records a goal

In the same transaction as score entry:

1. Apply the score update and insert the score event.
2. Find and lock the active Next Goal market.
3. If it is open, record a locked transition.
4. Settle it against the option matching the scoring team.
5. Store the settled market ID on the score event.
6. Create/open the next 90-second Next Goal market.
7. Store the opened market ID on the score event.
8. Store the host mutation receipt.
9. Emit score, market, bet, balance, and ladder change events after the transaction succeeds.

No active market is not a reason to reject valid score entry. The score must still succeed; log the missing market condition and open the next market.

### Quarter end

- Lock and void any unresolved active Next Goal market.
- Refund every stake through the normal void path.
- Settle the Squares quarter result as Phase 1 already does.
- Freeze the quarter ladder result in the response/audit trail.
- Q4 ends in final state and opens no new market.

### Global pause

- Pause rejects new/increased bets.
- It does not stop score entry, Squares, settlement, or projector refresh.
- It does not extend `locks_at`.
- A market whose clock expires while paused remains effectively locked after resume.

---

## 9. Parimutuel settlement

For winning option `W`:

```text
winning_pool = sum(stakes on W)
losing_pool  = sum(stakes on all other options)
```

Rules:

```text
If winning_pool = 0:
  void the market
  refund every stake
  payout = stake and profit = 0 for every bet

If losing_pool = 0:
  settle the market
  every winning backer receives their stake back
  payout = stake and profit = 0

Otherwise, for each winning bet:
  payout = stake + floor(stake * losing_pool / winning_pool)
  profit = payout - stake

For each losing bet:
  payout = 0
  profit = -stake
```

Settlement function requirements:

- Lock the market, its options, affected bets, and affected player rows.
- Return the existing result immediately when `settled_at` is already non-null.
- Never credit a player twice.
- Append payout/refund ledger rows and update materialized balances in the same transaction.
- Store winning pool, losing pool, and flooring dust on the market.
- Never distribute more than the losing pool.
- Mark all bets settled consistently before returning.
- Emit events only after successful commit.

Canonical worked example:

- Winning pool: 500.
- Losing pool: 1,000.
- Player stake on winner: 50.
- Payout: `50 + floor(50 × 1000 / 500) = 150`.
- Profit: 100.

---

## 10. Score undo with settled markets

Undo must continue to work for every latest score, including a goal that automatically settled a market.

For undoing a latest goal, in one transaction:

1. Lock the latest active score event and both linked markets.
2. Void the market opened by that goal.
3. Refund any stakes placed on the newly opened market, appending `refund` ledger rows.
4. Find every payout/refund ledger row created by settlement of the prior market.
5. Append exact negative reversal rows with `reversal_of_id` links.
6. Reduce affected player balances by those credits. Refunding the newly opened market first ensures Bones spent there are restored before payout reversal.
7. Clear settlement values from the prior market and its bets.
8. Restore the prior market to `open` only if server time is still before its original lock; otherwise restore it to `locked`.
9. Soft-void the score event and recompute score totals using the existing Phase 1 rule.
10. Store an idempotent undo receipt and emit reconciliation events.

An undo remains forbidden after its quarter result is settled, matching Phase 1.

Tests must prove that goal → bet on new market → undo leaves balances, pools, bets, market states, and ledger totals consistent.

---

## 11. Ladder definitions

The ladder is based on settled bet profit, never current balance and never total Bones staked.

```text
bet profit = payout - stake
```

- Winner: positive or zero profit.
- Loser: negative stake.
- Void: zero profit.

### Quarter ladder

- Sum `bets.profit` for settled markets in the current quarter.
- Include only markets with `counts_toward_quarter_prize = true`.
- Reset naturally by filtering on quarter; do not rewrite historical profit.
- Sort by profit descending, then nickname case-insensitively for a deterministic tie display.
- The top three are shown at the siren. Prize handling remains outside the app and non-monetary.

### Top Dog

- Sum profit across all settled, non-reversed markets.
- In Phase 2 this is Next Goal only; later phases may add futures.
- Sort by profit descending, then nickname case-insensitively.
- Unstaked Bones contribute zero.

Ladder snapshots should include rank, player ID, nickname, profit, and whether the row is the requesting guest.

---

## 12. Edge-function API

Keep the existing `POST kennel-api` envelope and headers:

- Body: `{ action, ...payload }`.
- `X-Player-Token` for guest actions.
- `X-Host-Token` for host actions.
- `Idempotency-Key` for mutations.

### Existing actions to extend

- `public_snapshot`: add active market, pool split, server timing, quarter ladder, and Top Dog top five.
- `join`: apply Bones grants and return balance/ladder/market data.
- `player_snapshot`: add balance, the guest's active bet, and ladder positions.
- `host_snapshot`: add markets, pools, bet counts, full ladder, and settlement audit fields.
- `record_score`: add automatic goal settlement/new-market creation.
- `undo_latest_score`: add market-cycle reversal.
- `start_quarter`: open the first market for that quarter.
- `end_quarter`: void the unresolved active market and freeze quarter standings.
- `set_pause`: continue to freeze betting only.
- `link_purchase`: apply only newly earned square bonus grants.

### New actions

```text
place_bet
  input: marketId, optionId, stake
  auth: player token
  idempotent: yes
  returns: player snapshot

lock_market
  input: marketId
  auth: host token
  idempotent: yes
  returns: host snapshot

settle_market
  input: marketId, winningOptionId
  auth: host token
  idempotent: yes
  returns: host snapshot

void_market
  input: marketId, reason
  auth: host token
  idempotent: yes
  returns: host snapshot

open_next_goal
  input: optional lockSeconds for recovery/testing, default 90
  auth: host token
  idempotent: yes
  returns: host snapshot
```

Manual settlement/opening is a recovery tool. The normal operating path remains host score entry.

### Error copy

Return guest-readable messages for:

- Market has locked.
- Betting is paused.
- Not enough Bones.
- Stake must be positive.
- Market cap reached.
- Existing selection cannot be changed.
- Guest/host session expired.
- Market is already settled or void.

Avoid exposing SQL, table names, stack traces, tokens, or internal IDs beyond the resource IDs already required by the UI.

---

## 13. Snapshot contracts

Add shared TypeScript types for:

```text
MarketStatus
MarketOption
MarketSummary
PlayerMarketPosition
LadderEntry
LedgerEntry (host/player-limited view only)
SettlementSummary
```

### Public snapshot

Add:

- `activeMarket` or null.
- `quarterLadder` top five.
- `topDogLadder` top five.
- Authoritative `serverNow` already exists and remains mandatory.

### Player snapshot

Add:

- `player.balance`.
- `player.quarterRank` and `player.topDogRank`.
- `activeBet` or null.
- Full quarter and Top Dog ladders.
- A small recent Bones activity list if it remains legible; this is secondary to the market.

### Host snapshot

Add:

- Active and recent markets.
- Option pools, bet counts, and settlement summary.
- Full current-quarter ladder and Top Dog ladder.
- Enough audit data to diagnose a void or settlement without exposing session tokens.

---

## 14. Frontend changes

### Punter experience

Keep Squares as the default tab. Add:

#### Kennel tab

- Balance prominent at the top, always labelled Bones.
- A short “No cash value” note near first use, without cluttering every action.
- Current Next Goal question and lock countdown.
- Home and away selection cards.
- Live pool-split bar with pool totals and percentages.
- Stake buttons: 25, 50, 100, Max.
- Current selection/stake after backing a side.
- Only allow increases on the selected option.
- Clear locked, paused, settled, void, refund, insufficient-balance, and no-active-market states.
- Disable controls immediately while a request is in flight; reuse one idempotency key for retries of that intent.
- Reconcile the whole view from the returned server snapshot.

#### Ladder tab

- Current-quarter ladder with the guest's row highlighted.
- Top Dog overall standings.
- Show rank, nickname, and signed net profit in Bones.
- Explain once that rankings use net profit, not balance.

### Host console

Score controls remain first and largest. Add below them:

- Current market title, countdown/effective status, and pool split.
- Bet count and total pool.
- Lock control.
- Settle control with explicit winning team selection and confirmation.
- Void control with confirmation and reason.
- Recovery button to open a Next Goal market when none is active.
- Current-quarter top three and full ladder access.
- Clear success/error feedback without displacing score controls.

Host score entry must still succeed if market processing has no active market; the response should make the recovery state obvious.

### Projector

Preserve the score and Squares grid as the dominant content. Add:

- Current Next Goal market.
- Large pool-split visualization.
- Lock countdown/status.
- Quarter ladder top five.
- A brief settlement result state before the next market replaces it, if this can be done without hiding score/Squares information.

### Responsive and accessible behavior

- Minimum comfortable touch targets for use in a crowded pub.
- No reliance on hover.
- Visible keyboard focus.
- Status changes announced with a polite live region where appropriate.
- Color is not the only indication of selected/winning/losing/locked state.
- Preserve projector legibility at distance and punter usability around 360 px width.
- Respect reduced-motion preferences.

---

## 15. Realtime, polling, and offline recovery

Extend the event list with:

- `market_updated`
- `bet_updated`
- `balance_updated`
- `ladder_updated`

Keep the existing score, undo, quarter, pause, and grid events.

Correctness must not depend on realtime delivery:

- Every mutation returns a complete authoritative snapshot.
- Key-free hosted clients poll the public edge function on the existing short interval.
- Realtime clients refresh the same snapshot on events rather than applying untrusted balance deltas.
- On reconnect, fetch a fresh snapshot before re-enabling actions.
- Never automatically replay an uncertain bet with a new idempotency key.
- If a request times out, retry only with its original key.
- Show the offline banner whenever the browser or realtime/polling path is unavailable.

---

## 16. Test-first plan

Settlement tests must be committed before Kennel UI code.

### 16.1 Pure settlement unit tests

Add a pure TypeScript reference implementation used for tests/documentation, mirroring server integer arithmetic. Cover:

1. Canonical normal case: winning pool 500, losing pool 1,000, 50 stake pays 150/profits 100.
2. Zero winning pool: market voids and every stake is refunded.
3. Zero losing pool: all winners receive stake back and profit zero.
4. Single bettor: stake back, profit zero.
5. Dust: flooring never distributes more than losing pool and records the remainder.
6. Multiple uneven winners.
7. Settle twice: second call creates no additional credits.
8. Sum invariant: payouts plus dust do not exceed total pool.

### 16.2 Database integration tests

Against the Phase 2 backend branch:

- Courtesy grant is exactly once.
- Square bonus increments exactly once and caps at five.
- Concurrent/retried bet request does not double-stake.
- Same player cannot choose two options in one market.
- Same-option stake can increase while open.
- Bet after server lock fails even with a forged client time.
- Bet while globally paused fails.
- Insufficient balance fails without partial writes.
- Market cap is enforced against total player stake.
- Every bet change keeps `option.pool_bones = SUM(bets.stake)`.
- Normal settlement balances, ledger, bets, market audit, and ladder agree.
- No winning backer produces a void and complete refunds.
- Void is idempotent.
- Goal settles one market and opens exactly one successor.
- Behind changes no market.
- Goal retry does not settle/open twice.
- Undo goal reverses settlement, refunds successor bets, and restores consistent balances.
- Quarter end voids the unresolved market and preserves Phase 1 Squares settlement.
- RLS/advisor checks show no public mutation path.

### 16.3 Component tests

- Pool split renders zero/one-sided/two-sided cases.
- Countdown uses server offset and reaches locked state.
- Existing choice disables the other option.
- Stake controls reflect balance/cap without becoming authoritative.
- Ladder uses profit and highlights the guest.
- Squares remains the initial tab.

### 16.4 Browser flows

At minimum:

1. Join → receive courtesy Bones → open Kennel → place a bet → see balance/pool update.
2. Square-linked guest receives the correct capped bonus.
3. Two guests back different teams → host records a goal → payouts and ladder update.
4. Nobody backs the scorer → all stakes refund and market shows void.
5. Host records behind → market remains unchanged.
6. Host records goal → new 90-second market appears.
7. Host undoes goal after a successor bet → all views reconcile.
8. Pause blocks betting but host scoring and Squares still work.
9. Projector shows score, Squares, active market, and top five.
10. 360 px mobile viewport and projector viewport have no critical overflow.

### 16.5 Load rehearsal

Add a development-only script that creates 60 clearly prefixed synthetic guests and places randomized bets through the real edge-function API.

Requirements:

- Refuse to run unless explicitly pointed at a non-production backend branch.
- Use unique idempotency keys.
- Exercise simultaneous stakes and snapshot reads.
- Print latency/error summaries, not credentials.
- Provide a cleanup path for synthetic rows.
- Never run it against the production parent during implementation.

---

## 17. Expected file-level work

Likely additions/changes:

- `migrations/<timestamp>_phase-2-kennel.sql`
  - Tables, constraints, indexes, grants, RLS, ledger immutability, RPCs, snapshot changes, score integration, and safe backfill.
- `functions/kennel-api.ts`
  - New actions, payload validation, token hashing, error mapping, and extended snapshots.
- `src/types.ts`
  - Market, bet, ledger, settlement, and ladder contracts.
- `src/lib/settlement.ts`
  - Pure integer reference calculation.
- `src/lib/settlement.test.ts`
  - Canonical tests before UI work.
- `src/lib/api.ts`
  - Betting and host-market methods.
- `src/lib/demo.ts`
  - Deterministic demo equivalents for local/offline UI tests.
- `src/hooks/use-live-snapshot.ts`
  - New refresh events while retaining polling fallback.
- `src/components/market-card.tsx`
- `src/components/pool-split.tsx`
- `src/components/ladder.tsx`
- `src/pages/punter-page.tsx`
  - Kennel and Ladder tabs; Squares remains default.
- `src/pages/host-page.tsx`
  - Recovery-safe market controls and ladder.
- `src/pages/screen-page.tsx`
  - Market/pool/top-five display subordinate to score/Squares.
- `src/styles.css`
  - Mobile, projector, status, accessibility, and reduced-motion states.
- `scripts/verify-backend.mjs`
  - Phase 2 integration cases and cleanup.
- `scripts/load-phase-two.mjs`
  - Guarded 60-player branch-only load rehearsal.
- `tests/e2e/phase-two.spec.ts`
  - Core end-to-end story.

Prefer focused components over turning the already-large page files into larger monoliths. Do not restructure Phase 1 simply for aesthetic reasons.

---

## 18. Implementation sequence

### Step 1 — Establish the isolated environment

- Update local `main`.
- Create both Phase 2 branches.
- Point `.env.local` to the backend branch without committing it.
- Confirm Phase 1 smoke tests pass before any Phase 2 change.

### Step 2 — Write settlement specification in executable form

- Add the pure integer settlement function and canonical tests.
- Do not edit Kennel UI before these tests pass.

### Step 3 — Add schema and server transactions

- Create one coherent migration.
- Add grants, markets, bets, ledger, settlement, ladder, and goal-undo RPCs.
- Apply only to the backend branch.
- Run integration tests and advisor scans.

### Step 4 — Extend the edge function and shared contracts

- Add strict action validation and complete snapshot responses.
- Deploy the function to the backend branch.
- Verify all actions directly before UI integration.

### Step 5 — Build host recovery controls

- Add current market state, lock, settle, void, and open controls.
- Extend record score and undo flows.
- Verify on phone and laptop sizes.

### Step 6 — Build the punter core loop

- Add balance, Kennel market card, pool split, stakes, current position, and clear server errors.
- Preserve Squares as default and always usable.

### Step 7 — Build ladder and projector additions

- Add quarter/Top Dog tabs and projector top five.
- Keep score and Squares visually dominant.

### Step 8 — Resilience and load rehearsal

- Exercise polling, realtime refresh, offline/reconnect, request retry, and 60-player concurrency.
- Reconcile ledger totals, balances, bets, and pools after the run.

### Step 9 — Preview and gate

- Run unit, component, integration, browser, build, and security checks.
- Deploy a Phase 2 branch preview.
- Demo the complete story on a phone-sized viewport and projector-sized viewport.
- Stop for approval before production merge.

---

## 19. Acceptance criteria

Phase 2 is ready for approval only when all are true:

- [ ] A new guest gets exactly 1,000 courtesy Bones.
- [ ] A linked square-holder gets exactly 250 per square, capped at five.
- [ ] Grant retries and purchase re-linking cannot duplicate Bones.
- [ ] Squares is still the default punter view.
- [ ] A guest can back one Next Goal option and increase only that option while open.
- [ ] Balance and pool changes occur only on the server.
- [ ] Server time rejects late bets.
- [ ] Pause rejects bets but does not block score entry or Squares.
- [ ] A behind leaves the market untouched.
- [ ] A goal settles the current market and opens exactly one successor.
- [ ] A market with no winning backers voids and refunds every stake.
- [ ] A one-sided winning market returns stakes with zero profit.
- [ ] Settlement and score retries cannot double-pay or double-open.
- [ ] Undo of a goal restores score, markets, balances, pools, bets, and ledger consistency.
- [ ] Quarter and Top Dog ladders use net profit, not balance or turnover.
- [ ] Quarter end resolves the active market and still settles the correct Squares winner.
- [ ] Host recovery controls work from both phone and laptop.
- [ ] Projector shows score/Squares first, plus current pool and top five.
- [ ] Offline/reconnect presents clear state and reconciles on return.
- [ ] The 60-player branch load rehearsal completes without invariant violations.
- [ ] All automated tests and production build pass.
- [ ] Backend advisor reports no unresolved critical or warning findings introduced by Phase 2.
- [ ] The phase is demoed, approved, merged, deployed, and live-smoke-tested.

---

## 20. Operational rehearsal checklist

Before the event, Harry should:

- Rotate and privately record the production host PIN.
- Import the final Zeffy purchaser CSV and verify square links/bonuses.
- Print the backup Squares grid.
- Test the host console on the actual phone and laptop.
- Test the projector and pub Wi-Fi.
- Rehearse: join, bet, lock, goal settlement, behind, void, pause, undo, quarter end, and reconnect.
- Confirm all public copy says Bones have no cash value and all prizes are non-monetary.
- Get a local read on Colorado charitable gaming before promoting The Kennel.

---

## 21. Decisions that should not be reopened without evidence

- Squares remains the primary product and default tab.
- The browser submits intents; Postgres transactions own balance and pool truth.
- The ladder is net settled profit.
- One player may select only one option per market.
- Increasing that same selection is allowed before lock.
- The lock clock is server-authoritative.
- No winning pool means void/refund, not redistribution to nobody.
- Flooring dust is discarded and audited.
- A behind never changes the Next Goal market.
- A goal drives score, settlement, and the next market in one idempotent transaction.
- Goal undo reverses market effects through append-only ledger reversals.
- Unlinking squares does not claw back promotional Bones already granted.
- Correctness does not depend on realtime delivery.
- No frontend admin key.
- No payments and no sports feed.

If implementation evidence reveals a conflict among these decisions, stop and document the exact conflict before changing behavior.

---

## 22. Final handoff

The next implementation thread should begin by reading, in order:

1. `claude.md` for the product contract and hard constraints.
2. `phase-2.md` for this phase's resolved implementation plan.
3. `AGENTS.md` for InsForge-specific repository guidance.
4. The current migration, edge function, shared types, API wrapper, live snapshot hook, and three page components.

Then it should verify Phase 1 locally, create the isolated code/backend branches, and write the settlement tests before any Phase 2 interface code.
