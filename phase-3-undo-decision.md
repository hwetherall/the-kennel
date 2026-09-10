# Decision needed: undoing a goal whose payout was spent in a concurrent market

Prepared 10 September 2026. This is the decision required by
[phase-3.md](phase-3.md) section 4 and delivery step 3. **No Phase 3 market
code should be written until it is answered**, because both Studs v Spuds and
Futures create markets that are open at the same time as a Next Goal market.

## Why Phase 2 does not have this problem

`kennel_undo_latest_score` (migrations/20260907111154_phase-2-recovery-undo.sql)
takes the shared game lock, then walks **later Next Goal markets in the same
quarter, newest first**, reversing each settlement and voiding it — and only
then reverses the payout made by the goal being undone. By the time the funding
payout is reversed, every Bone that payout could have been spent on has already
been refunded.

That ordering is load-bearing, not incidental. `ledger.balance_after` carries
`CHECK (balance_after >= 0)` (migrations/20260907102055_phase-2-kennel.sql:88),
and `kennel_write_ledger` writes a ledger row for every mutation. So a reversal
that would take a balance below zero does not produce a negative balance — it
raises a constraint violation and **aborts the entire undo transaction**.

## What breaks in Phase 3

A Studs market opens at the start of a quarter and stays open for five minutes,
overlapping several Next Goal markets. Its `sequence` is lower than the Next
Goal markets that follow, and its `type` is not `next_goal`, so the undo loop's
`type = 'next_goal' AND sequence >= …` filter never touches it.

1. A goal pays a guest 1,500 Bones.
2. The guest stakes those Bones on the already-open Studs market.
3. The host mis-tapped, and undoes the goal.
4. The loop refunds later Next Goal markets, but not the Studs stake.
5. Reversing the goal's payout drives that guest's `balance_after` negative.
6. The `CHECK` fires. **The undo fails and the host cannot correct the score.**

This happens even though Studs has never settled, so restricting Studs
settlement until the siren does not help. The observable consequence is not a
corrupted balance; it is a host who cannot fix a mis-tap at 1am, which
[claude.md](claude.md) section 9 names as a guaranteed event.

## Option A — void and refund the affected market (recommended)

When undo finds stakes placed in an unresolved market after the goal's ledger
checkpoint, void and refund **that whole market** before reversing the goal's
payout. Earlier unaffected markets stay intact.

- Record a ledger sequence checkpoint on each goal, after its settlement and
  before the mutation returns, so "after the goal" is a server fact and not a
  client timestamp.
- Extend the existing newest-first loop to include unresolved markets of any
  type in that quarter holding post-checkpoint stakes. Reuse
  `kennel_finish_market(id, NULL, reason, request)` — the same void-and-refund
  primitive the loop already calls. One transaction, same lock order.
- Do not reopen the market or extend its deadline.
- The undo confirmation tells the host which predictions will be refunded;
  guests see the refund reason.

**Cost:** guests who staked on Studs *before* the goal also get refunded, for a
mis-tap that had nothing to do with them. Blast radius is one market, one
quarter, and the checkpoint keeps markets with no post-goal stakes untouched.

**Benefit:** no new accounting concepts. Undo keeps working in every case. It
reuses the settled Phase 2 ordering rule rather than inventing a second one.

## Option B — cancel only the affected guests' bets

Refund just the bets that consumed the payout, decrement the pool, and leave the
market open.

**Cost:** needs a stake-reversal mechanism that does not exist yet, plus
selection semantics for cases the ledger cannot answer on its own — a guest who
staked partly from their own Bones and partly from the payout, or who increased
an existing position, holds one `bets` row with a `UNIQUE (market_id,
player_id)` constraint and two stake ledger rows. It also means a live pool that
moves for reasons no guest on the projector can see, mid-market. phase-3.md
section 4 requires this to be designed and audited separately before any code.

**Benefit:** unaffected guests keep their positions.

## Not on the table

Refusing the undo, or relaxing the non-negative balance guard. phase-3.md
section 4 rules both out explicitly, and the second would break the ledger audit
trail that every other invariant is checked against.

## The question

**Confirm Option A, or ask for Option B to be designed first.** Option A is
roughly a migration plus tests on the existing loop. Option B is a new
subsystem, and section 4 requires its design to be approved before it is coded.

Once answered, record the choice here and in `phase-3-progress.md`, then the
tests named in phase-3.md section 10 can be written: pre-goal stakes,
post-goal increases, replayed idempotency keys, and later Next Goal spending of
the resulting refunds.
