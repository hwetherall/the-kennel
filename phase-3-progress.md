# Phase 3 progress

Updated 10 September 2026. Follow [phase-3.md](phase-3.md) in order.

## Current position: Phase 2 promoted; Phase 3 not started

**Phase 2 shipped to production on 10 September 2026.** Harry approved the full
promotion sequence without a prior hands-on demo, on the recorded evidence plus
the re-verification below. Actual identifiers:

- Code: PR #4 merged as `e867c8b` on `main`.
- Backend: `branch merge phase-2-kennel` applied 23 additions and 13
  modifications with zero conflicts. The branch is now in `merged` state. The
  `kennel-api` edge function was promoted **by the merge itself**, as a
  `[DATA] edge_function` row, so it needed no separate `functions deploy`.
- Production site: **first ever deployment**, live at
  <https://bk8ptwjs.insforge.site>, deployment `d1fff339-6c79-4bb8-8f81-3846bf39a849`.
  Before this the URL returned Vercel `DEPLOYMENT_NOT_FOUND`; Phase 1 had only
  ever been demoed on its own branch preview.
- Production edge: <https://bk8ptwjs.function2.insforge.app/kennel-api>.
- Production API base: <https://bk8ptwjs.us-west.insforge.app>.

Verified on the production project after the merge:

- Tables `markets`, `market_options`, `bets`, `ledger` present; 29 `kennel_*`
  functions; RLS on all four economic tables with the `client access denied`
  policies in place.
- The three table diffs the merge preview reported as "not auto-applied" did
  land, through the migration records that run first: `players` +
  `courtesy_granted_at`/`bonus_squares_granted`, `score_events` +
  `settled_market_id`/`opened_market_id`, `quarter_results` + `quarter_ladder`.
- `mutation_receipts_pkey` is `PRIMARY KEY (action, idempotency_key,
  actor_fingerprint)`, so idempotency is scoped per action and actor.
- `ledger_immutable` trigger on `kennel_guard_ledger` is active.
- `public_snapshot` over the production edge returns 100 squares, `pre_match`,
  quarter 1, version 1.
- The deployed bundle is built against `https://bk8ptwjs.us-west.insforge.app`,
  not the branch, and the dead-code-eliminated local-demo branch confirms
  `VITE_INSFORGE_URL` was present at build time. `VITE_INSFORGE_URL` and
  `VITE_INSFORGE_ANON_KEY` are set as persistent deployment env vars.
- Read-only live browser smoke, five checks, no page errors: punter at 390px
  renders 100 squares and 10 row headers against the live backend; no horizontal
  overflow at 360px; `/screen` fits 1920×1080 with zero vertical overflow;
  `/host/print` renders 100 squares; `/host` presents its PIN gate.
- Advisor rescan on the branch before promotion: 0 critical, 0 warning, 7
  informational unused-index findings. Note this is 7, not the 3 recorded
  earlier. `pg_stat_statements` is still unavailable, so the historical
  slow-query rule did not run.

**Production data is pristine and deliberately untouched: 0 players, 0 ledger
rows, 0 markets, 0 score events, 0 purchases, 0 sold squares, 0 quarter
results.** No write-path smoke test was run against production, because
`ledger_immutable` makes a courtesy-grant row permanent — a synthetic guest
could not be cleaned up afterward. The write paths are proven on the branch
instead. Grid digits are already randomly assigned; teams are still the
placeholder "Home"/"Away", and the Zeffy import has not been run.

`.env.local` still points at the `phase-2-kennel` branch, not production, which
keeps every local script and dev server off the production project.

## Superseded: the Phase 2 prerequisite gate

Prerequisite PR: https://github.com/hwetherall/the-kennel/pull/4
Last code commit, and the head the baseline below was verified at: `5496558`.
The branch carries six code commits on top of `main` (`197e496`): handoff
`762ed56`, then `7c76335`, `2ba8c44`, `4f5e47f`, `4b6da0f`, and `5496558`, plus
documentation commits that change no code. No code PR or backend has been merged
as part of this work.

`2ba8c44` originally held the concurrent Squares digit-order edits out of this
increment, but `5496558` landed them on this branch, so they are now in the
PR's scope and are listed below. The earlier distinction between an isolated
63-test PR and a 64-test working tree no longer exists: the PR is the working
tree.

The existing code branch is `codex/phase-3-studs-futures`. The selected backend
is the ready, schema-only `phase-2-kennel` branch. No Phase 3 backend has been
created and no Phase 3 markets have been implemented or exposed.

The Phase 2 prerequisite increment adds:

- Punter Next Goal cards, Bones balance/activity, fixed selections and increases,
  pool percentages, server-relative countdowns, refunds, and profit ladders.
- Host market lock/settle/void/reopen recovery, explicit result confirmation,
  audits, and quarter standings below the score controls.
- Projector market/top-five additions and a board that fits a 1920×1080 display.
- Full snapshot reconciliation ordered by game version and server timestamp,
  protection against old-session responses, polling with realtime, and reconnect
  reconciliation before enabling actions.
- Original-key uncertain retries; guest requests and host requests survive a page
  reload in session storage. No optimistic balance or pool mutation.
- A deterministic local synthetic Kennel simulation with shared browser state,
  settlement, recovery undo, receipts, and stored quarter standings.
- A guarded real-HTTP 60-player rehearsal and live-preview browser verification.

It also carries one change to the Phase 1 Squares board, outside the original
prerequisite scope and needing review as a Squares change: the grid now renders
its row and column headers as a fixed `0`-`9` sequence and resolves each cell by
looking the drawn digit up in `grid.rowDigits`/`grid.colDigits`, instead of
rendering the headers in drawn order. Square ownership and the live-square
highlight are unchanged, because both digit arrays are permutations of `0`-`9`.
`/host/print` renders the same component, so the printed backup grid keeps the
same layout as the screen.

No existing migration file was changed or reapplied. The branch still has the
three Phase 2 migrations recorded in `phase-2-progress.md`.

## Verified evidence

- Handoff baseline: 50 unit/component/edge tests, production build, six Phase 1
  browser tests, both rolled-back database suites (including five recovery
  scenarios), and 17 read-only deployed edge checks passed.
- Re-verified at head `5496558` on 10 September, from a single tree: 64
  unit/component/edge tests in eight files, production build, 10 phone and
  desktop browser flows, `verify-phase-two.mjs`, `verify-phase-two.mjs
  --undo-recovery`, and `verify-phase-two-edge.mjs` (17 read-only deployed
  checks). Both database suites rolled their fixtures back.
- The 10 browser flows cover 360px width, goal-payout spending and undo, pause,
  offline events, quarter finalization, recovery confirmation, and projector fit
  at 1920×1080.
- Production build passes with the existing SDK `crypto` externalization warning.
- Branch preview: https://bk8ptwjs-zww.insforge.site
  (deployment `51b66051-81ce-45e8-9187-cd60864155ac`).
- Branch edge: https://bk8ptwjs-zww.function2.insforge.app/kennel-api
- Advisor scan `e6b88770-8f51-4209-82a7-d2630ba9e250` completed with zero critical,
  zero warning, and three informational unused-index findings. Historical
  slow-query analysis did not run because `pg_stat_statements` was unavailable.
- Backend merge dry-run reported 23 additions, 13 modifications, zero conflicts.
  The refreshed final dry-run includes the deployed connection retry and no
  destructive table drops. Its three migration records carry the table changes that the standalone table
  diff reports as unsupported. The repeated table/index creation is guarded by
  `IF NOT EXISTS`; function replacements retain the migration-established access
  boundary. No user-table data is promoted by the merge.

## Load finding and recovery

The first real simultaneous-join rehearsal exposed the branch's 30-connection
limit. Postgres logged “too many clients already”; the SDK surfaced this as
`PGRST000` with a generic connection-error message. The edge RPC wrapper retries
refused connections while preserving the exact actor, arguments, and idempotency
key. It never retries a deliberate product validation error, and returns a safe
503 after its bounded retry window. Tests cover both Postgres `53300` and observed
PostgREST `PGRST000` errors.

With explicit approval, only the isolated `phase-2-kennel` branch was temporarily
resized from Nano to Small on 9 September. It still reported `max_connections =
30`, so this confirmed that larger RAM alone does not remove the connection-admission
limit. Diagnostics showed the platform's API-key validation and gateway proxy also
compete for those connections. The production parent was never resized.

The browser client now retries uncertain gateway responses up to eight times with
exponential jitter. It sends the exact same player session token for joins and the
same idempotency key for economic and host mutations. The rehearsal uses the same
bounded recovery and reports recovered attempts. It retains 60 concurrent player
wagers, ten deliberately overlapping duplicate wager requests, and twelve live
audience reads; it no longer adds a second snapshot request for every player, which
had created an artificial 130-request connection storm.

The final Small-branch run passed on 9 September: 60 guests, 167 authenticated
logical calls, four expected validation rejections, 65 recovered transient gateway
responses, and zero unrecovered errors. Latency was p50 1064 ms, p95 1758 ms, and
max 1905 ms. Balance, pool, payout-plus-dust conservation, reversal, and immutable
ledger invariants all held. The live branch preview also passed the phone, host,
projector, and print flow, including offline/reconnect and guest/host lost-response
original-key retries. See `phase-2-rehearsal-results.json`.

Cleanup restored the two pre-existing players and their two opening ledger entries,
with zero markets, bets, or receipts. The branch was returned to Nano and confirmed
active. Post-rehearsal diagnostics found no locks or slow queries. The existing
advisor scan still has zero critical and warning findings and three informational
unused-index findings; its historical slow-query rule is unavailable because
`pg_stat_statements` is not installed.

The two-player authenticated HTTP and live-browser rehearsal passes. Its 33 HTTP
checks have zero unexpected errors and four deliberate validation rejections;
latency p50 235 ms, p95 439 ms, max 493 ms. The live preview separately proves
two guests staking, goal payout, deliberately lost HTTP response after commit,
guest and host original-key retries after reload, goal undo, actual browser offline/reconnect,
siren, and phone/host/projector/print. Balances, pools, payout+dust conservation,
exact reversals, and the append-only guard reconcile. See
`phase-2-smoke-results.json`. Synthetic rows were cleaned up afterward.

The platform incident command suggested OOM, but its cited restart timestamp
matches branch provisioning rather than this rehearsal. That output is not
accepted as evidence of a current OOM; the verified finding is connection
exhaustion and associated API failures under the burst.

Rehearsal cleanup refuses production, an unready/wrong branch, nonempty market/
score/purchase fixtures, unrecognized guests, and changed existing guest economic
state. It preserves the pre-existing guest and ledger, original Squares and game,
keeps the game version increasing, and drains concurrent requests before cleanup.
Only the grant routine's expected `updated_at` change is allowed on an existing
unchanged guest. Interrupted runs retain an ignored, mode-0600 manifest for
`node scripts/rehearse-phase-two.mjs --cleanup`.

## Remaining sequence

1. ~~Review PR #4 and obtain Phase 2 production promotion approval.~~ **Done**
   10 September; approved without a prior hands-on demo.
2. ~~Promote Phase 2, merge its PR, and smoke-test the live site.~~ **Done** —
   see the promotion record at the top of this file. Still outstanding from this
   step: Harry's own phone, host, projector and print pass over the live site,
   and a decision on whether to run a write-path smoke test on production given
   that its ledger rows cannot be removed.
3. Phase 3 section 4 is **resolved** in `phase-3-undo-decision.md`, and needs no
   policy decision. Harry corrected the Studs v Spuds timing on 10 September:
   Studs is a break game, open during the break before the quarter it covers,
   locked at that quarter's bounce, and reconciled at the siren. It is never open
   during play, so a goal payout can only ever be spent on a Next Goal market,
   which the existing Phase 2 undo loop already unwinds. What replaces the policy
   is a database-level invariant: no market other than Next Goal is ever `open`
   while `period_status = 'live'`. The residual risk of reversing an already-paid
   Studs settlement stays deferred per section 5, mitigated by the draft/preview/
   confirm sequence.

   Harry also decided on 10 September that a quarter carries **two or three
   matchups**, count at the host's discretion, all open together during the
   preceding break. `claude.md` section 7 and `phase-3.md` sections 3 through 12
   were corrected to match both facts; the earlier "one pair per quarter, opens
   at the start of the quarter, locks five minutes in" model is gone from the
   specs.
4. Only then create `phase-3-studs-futures` from the updated production backend
   parent. InsForge backend branches cannot nest.
5. Continue schema/transaction tests, API, host, punter, projector, mixed-market
   rehearsal, preview, and final Phase 3 approval in the plan's specified order.

Physical phone/pub/projector rehearsal, production promotion, and all Phase 3
acceptance criteria remain open. The Phase 3 undo choice is closed. This is not a
declaration that Phase 2 or Phase 3 is complete.
