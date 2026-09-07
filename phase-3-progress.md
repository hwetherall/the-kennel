# Phase 3 progress

Updated 7 September 2026. Follow [phase-3.md](phase-3.md) in order.

## Current position: Phase 2 prerequisite gate

The existing code branch is `codex/phase-3-studs-futures`, based on `197e496`
with handoff commit `762ed56`. The selected backend is the ready, schema-only
`phase-2-kennel` branch. No Phase 3 backend has been created and no Phase 3
markets have been implemented or exposed.

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

No existing migration file was changed or reapplied. The branch still has the
three Phase 2 migrations recorded in `phase-2-progress.md`.

## Verified evidence

- Baseline: 50 unit/component/edge tests, production build, six Phase 1 browser
  tests, both rolled-back database suites (including five recovery scenarios),
  and 17 read-only deployed edge checks passed.
- Current workspace: 64 unit/component/edge tests pass. This includes one
  concurrently added Squares-order test outside this prerequisite increment.
- Ten phone/desktop demo browser flows pass, including 360px width,
  goal-payout spending and undo, pause, offline events, quarter finalization,
  recovery confirmation, and projector fit at 1920×1080.
- Production build passes with the existing SDK `crypto` externalization warning.
- Branch preview: https://bk8ptwjs-zww.insforge.site
  (deployment `cf4510f0-ac83-412b-9fa7-7c7de8c739aa`).
- Branch edge: https://bk8ptwjs-zww.function2.insforge.app/kennel-api
- Advisor scan `e6b88770-8f51-4209-82a7-d2630ba9e250` completed with zero critical,
  zero warning, and three informational unused-index findings. Historical
  slow-query analysis did not run because `pg_stat_statements` was unavailable.
- Backend merge dry-run reported 23 additions, 13 modifications, zero conflicts.
  Its three migration records carry the table changes that the standalone table
  diff reports as unsupported. The repeated table/index creation is guarded by
  `IF NOT EXISTS`; function replacements retain the migration-established access
  boundary. No user-table data is promoted by the merge.

## Load finding and recovery

The first real simultaneous-join rehearsal exposed the branch's 30-connection
limit. Postgres logged “too many clients already”; the SDK surfaced this as
`PGRST000` with a generic connection-error message. The edge RPC wrapper now
retries refused connections with bounded exponential jitter while preserving
exact actor, arguments and idempotency key. It never retries a deliberate product
validation error, and returns a safe 503 after six failed attempts. Tests cover
both Postgres `53300` and observed PostgREST `PGRST000` errors.

Two branch function deployment attempts returned a provider-side 502; a later
attempt succeeded. The corrected handler is deployed, but the 60-player burst still fails on Nano:
additional observed responses include socket resets, `PGRST002` schema-cache
failures, and transient API-key validation failures under connection pressure.
This is an unresolved load gate; it is not treated as successful through retries.
A temporary resize to Small (2 GB RAM, $0.0268/hour) and return to Nano has been
requested but not authorized or performed.

The two-player authenticated HTTP and live-browser rehearsal passes. Its 33 HTTP
checks have zero unexpected errors and four deliberate validation rejections;
latency p50 244 ms, p95 466 ms, max 467 ms. The live preview separately proves
two guests staking, goal payout, deliberately lost HTTP response after commit,
original-key retry after reload, goal undo, actual browser offline/reconnect,
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

1. Resolve the 60-player load gate; the two-player HTTP/preview flow is verified. Refresh
   the merge dry-run after the final edge deployment.
2. Open the scoped prerequisite PR, demo the preview, and obtain Phase 2 production
   promotion approval. No production backend, live-site, or code merge is approved
   by the earlier backend/API-only code-integration exception.
3. Promote Phase 2, merge its PR, and smoke-test the live site.
4. Present and obtain explicit confirmation of the cross-market undo policy in
   Phase 3 section 4. It remains **unconfirmed** and unimplemented.
5. Only then create `phase-3-studs-futures` from the updated production backend
   parent. InsForge backend branches cannot nest.
6. Continue schema/transaction tests, API, host, punter, projector, mixed-market
   rehearsal, preview, and final Phase 3 approval in the plan's specified order.

Physical phone/pub/projector rehearsal, production promotion, the Phase 3 undo
choice, and all Phase 3 acceptance criteria remain open. This is not a declaration
that Phase 2 or Phase 3 is complete.
