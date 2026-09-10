# Resolution of phase-3.md section 4: goal payouts and concurrent markets

Prepared 10 September 2026, revised the same day after Harry corrected the Studs
v Spuds timing model. This resolves the decision required by
[phase-3.md](phase-3.md) section 4 and delivery step 3.

**Outcome: the section 4 problem is unreachable, and no cross-market undo policy
is needed.** What is needed instead is one database-level invariant, described
below. Section 4 was written on an incorrect model of when Studs markets are
open, and so was the memo that first proposed a policy for it.

## The corrected Studs v Spuds model

Studs v Spuds asks which of two athletes will have more possessions **in the
coming quarter**. It is a break game, not an in-play game:

- It opens **during the break before** the quarter it covers, and pre-match for
  the Q1 matchups.
- It **locks at that quarter's opening bounce** and stays closed for the whole
  quarter.
- At the siren it is reconciled and paid out, and the next quarter's matchups
  open for the break.

So Studs resets every quarter, and a quarter may carry more than one matchup.
Next Goal is the continuous in-play game, resetting on every goal.

Section 4, phase-3.md section 5 ("Set `locks_at` from the authoritative
quarter-start instant plus five minutes"), and [claude.md](claude.md) section 7
("Opens at the start of the quarter, locks five minutes in") all describe a
market that is open *during* play for the first five minutes of a quarter. That
is what created the overlap with Next Goal. It is not the game.

The two games never compete for attention, which is a better product than the
overlap: Next Goal fills the play, Studs fills the break.

## Why the section 4 scenario cannot occur

Section 4's scenario needs a goal payout to be spent in a market that is open at
the time of the goal. Four guards in the applied Phase 2 schema close that off.

1. **Score events only exist during live play.** `kennel_record_score` refuses
   unless `period_status = 'live'` (migrations/20260907102055_phase-2-kennel.sql,
   `record_score` guard).
2. **Score undo only reaches into an unsealed quarter.**
   `kennel_undo_latest_score` refuses when `quarter_results` already holds a row
   for the latest score event's quarter, and `kennel_end_quarter` writes that row
   at the siren (same file, line 808). Undo can never reach back past a siren.
3. **Locked markets accept nothing.** `kennel_place_bet` raises `Market has
   locked` unless `status = 'open'` (line 281). A Studs market locked at the
   bounce cannot take a stake for the rest of the quarter.
4. **Nothing else is open during play.** Studs for the live quarter is locked at
   the bounce; Studs for the next quarter has not opened yet; both Futures locked
   at first bounce.

So during any live, unsealed quarter — the only window in which a goal payout
can be reversed — **the only market that can accept a stake is Next Goal**. That
is precisely the case the Phase 2 undo loop already walks, newest first, before
reversing the funding payout.

No ledger checkpoint, no cross-type undo loop, and no extra migration for this.

## What must be enforced instead

The above depends on an invariant that is currently a convention, not a rule:

> No market other than Next Goal is ever `open` while `period_status = 'live'`.

That belongs in the database, in the spirit of the `UNIQUE (market_id,
player_id)` constraint that makes hedging impossible. Concretely, and folding in
the lock-strategy work phase-3.md section 8 already calls for:

- Give markets a `lock_strategy` of `'deadline'` (Next Goal: a 90-second
  `locks_at`) or `'bounce'` (Studs and both Futures: locked by a game
  transition). `locks_at` becomes nullable for bounce-locked markets, rather than
  carrying an invented far-future date.
- `kennel_start_quarter` locks every `open` bounce-locked market in the same
  transaction that sets `period_status = 'live'`, under the existing game lock.
- `kennel_place_bet` rejects a bounce-locked market whenever `period_status =
  'live'`, so a stale `open` row can never accept a stake.
- Refuse to open a bounce-locked market while `period_status = 'live'`, so a host
  mis-tap cannot recreate the overlap that section 4 feared.

Studs and Futures then share one lock rule, tested once.

## The residual risk, which is a different problem

Reversing an **already-paid Studs settlement** hits the same
`ledger.balance_after CHECK (balance_after >= 0)` wall (line 88): the reversal
raises a constraint violation and aborts, rather than producing a negative
balance.

The path is real but narrow. In a break: Studs for the quarter just finished
settles and pays out, the next quarter's matchups are open in that same break, a
guest stakes the payout, and only then does the host find the disposal numbers
were wrong and want to correct them downward.

This is structurally the old problem with a different trigger, and the trigger is
what changed the stakes:

| | Trigger | Frequency |
|---|---|---|
| Section 4 as written | host mis-taps a score | guaranteed, per claude.md section 9 |
| Actual residual risk | mis-typed disposal number, found after explicit confirmation | rare, and preview-guarded |

Score undo — the guaranteed event — is off this path entirely.

**Recommendation: defer it, as phase-3.md section 5 already does** ("Any later
request to correct an already-paid result requires a separate audited recovery
design"). Deferral is safe because the mitigations are already in the plan and
cost nothing extra:

- Ending totals stay an editable draft, mutating no ledger, until explicit
  confirmation.
- A mandatory server-derived preview shows baselines, cumulative totals, quarter
  deltas, the selected winner or tie, pools, and the expected settlement audit
  before any Bones move.
- An explicit "Void and refund" path for missing or unresolvable stats, so the
  host is never pushed into guessing a number to get past the screen.

Ordering the break so that the previous quarter's Studs results are finalized
before the next quarter's matchups open would narrow the window further, but it
cannot close it — once the next markets are open the exposure returns — and it
would put disposal lookup back on the critical path, which phase-3.md section 6
deliberately keeps it off. Not worth the trade.

Fully eliminating it needs a real audited stake-reversal mechanism. For a
three-hour single-night app, a wrong number discovered after payout is
proportionately a manual host fix, not a subsystem.

## Consequences for the plan

- Phase 3 is **no longer blocked on a design decision**. The only remaining gate
  ahead of it is Phase 2's production promotion.
- phase-3.md section 4 is resolved by this analysis rather than by a policy
  choice. Its acceptance-gate line — "The new cross-market undo rule is
  explicitly confirmed, implemented, and verified" — is satisfied by the
  invariant above plus its tests.
- The section 10 tests change accordingly. Drop the cross-market goal-payout
  spending cases. Add: a bounce-locked market cannot be opened or staked during
  live play; `start_quarter` locks every bounce-locked market atomically; the
  five existing goal-undo scenarios still pass unchanged.
- These documents still carry the wrong Studs timing and need correcting:
  claude.md section 7, phase-3.md sections 4, 5, 6, 8, and 10.
