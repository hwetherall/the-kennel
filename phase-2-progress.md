# Phase 2 implementation progress

Updated 7 September 2026. The product contract and acceptance criteria remain in [phase-2.md](phase-2.md).

## Isolation

- Implementation branch: `codex/phase-2-kennel`, originally created from verified `main` at `66fe8e1`.
- Harry explicitly authorized merging this backend/API increment into `main` on 7 September 2026 and preparing `codex/phase-3-studs-futures` for a new-thread handoff. This code-integration exception does not declare Phase 2 complete or authorize production backend promotion.
- InsForge backend: `phase-2-kennel`, schema-only, ready, selected in the local CLI. Confirmed against the CLI branch list in this session.
- Branch API: `https://bk8ptwjs-zww.function2.insforge.app/kennel-api`.
- Ignored `.env.local` points to the branch. The prior configuration is backed up in ignored `.env.phase-one.local`. Browser polling uses no API key.
- Production has not received Phase 2 changes. No dependencies were added.

## Completed: settlement specification and core database work

- Settlement reference implementation and tests were committed before Kennel UI work (`0b5142f`). Exact integer arithmetic covers the canonical payout, empty/one-sided pools, dust, overflow, repeated settlement, and conservation across 3,600 pool combinations.
- Migration `20260907102055_phase-2-kennel.sql` was already applied to the branch at this handoff. It includes grants, ledger, market/bet constraints, betting and recovery RPCs, snapshot extensions, goal settlement and ordinary undo, quarter rollover, and server-only access.
- The ordinary transaction suite passes against the real branch with all test data rolled back. It covers grant retries/caps, same-choice increases, failed bets, server locking, pause with scoring, canonical settlement, retry receipts, ordinary successor-bet undo, re-settlement, voids, quarter rollover, and ledger/pool reconciliation.
- Added and applied `20260907105147_phase-2-winner-index.sql` on the branch to replace the narrow winner index with the full composite foreign-key index reported by the advisor.

## Completed: edge API and shared contracts

- Added `place_bet`, `lock_market`, `settle_market`, `void_market`, and `open_next_goal` to `functions/kennel-api.ts`.
- Added strict integer/UUID/body validation, preserved hashed guest/host tokens and idempotency keys, and limited database errors to deliberate guest-readable messages. Unexpected errors return generic HTTP 500 responses.
- Deployed the updated function only to the Phase 2 branch.
- Added market, position, ladder, ledger, settlement, and extended snapshot TypeScript contracts. The existing Phase 1 demo supplies empty market/ladder fields; it does not yet simulate the Kennel loop.
- Added edge-handler unit tests and `scripts/verify-phase-two-edge.mjs` for guarded, read-only deployed smoke checks. Successful authenticated HTTP mutations and concurrency remain to be rehearsed.

## Verification and limitations

- 50 local unit/component/edge-handler tests pass.
- All six existing Phase 1 phone/desktop browser tests pass, covering join/Squares, host score/undo, projector, and print.
- Production build passes; the existing InsForge SDK browser `crypto` externalization warning remains.
- 17 read-only deployed edge smoke checks pass, including snapshot fields, CORS, invalid intents, and guest/host authorization failures.
- `node scripts/verify-phase-two.mjs` passes on the branch and rolls back all test data.
- The database runner previously accepted a success marker anywhere in CLI output. A CLI argument failure echoing the SQL could falsely pass. It now requires the exact structured error field and uses `--` before SQL so leading comments cannot become CLI options. The core suite was rerun successfully after this correction.
- Advisor rescan `893d4537-5685-4468-94d6-36937ca096b4`: zero critical/warning findings, eight informational unused-index findings. The advisor's `slow-query` rule failed to execute; a separate current slow-query check returned an empty list. This does not establish historical query performance or load readiness.

## Completed: undo after intervening recovery settlements

Harry approved the recovery rule on 7 September 2026. Applied migration
`20260907111154_phase-2-recovery-undo.sql` only to the isolated Phase 2 branch.
The original migration remains unchanged.

Undo now visits all later Next Goal markets in the same quarter, starting at the
goal's opened market and working in descending sequence. It reverses each later
settled market through append-only ledger entries, then voids it and refunds its
stakes. Unresolved later markets are voided/refunded. Already-void markets retain
their existing refunds. Finally, the original market is restored using its
original lock time, and the score is undone in the same transaction.

The shared game lock protects the complete operation. Existing receipt-based
idempotency and the prohibition on undoing a settled quarter remain in force.
The approved rule is also recorded in section 10 of `phase-2.md` and backend
project memory.

Both branch suites pass, and all their data rolls back:

```sh
node scripts/verify-phase-two.mjs --undo-recovery
node scripts/verify-phase-two.mjs
```

The recovery suite covers five scenarios: the original spent-and-lost payout
failure; a chain of manually voided, manually settled, and unresolved markets;
consecutive goal undos through that chain; an original no-winning-backer refund;
and a goal entered with no active prior market. It checks restored scores and
balances, sole active market, later refunds, zero reversed ladder profit,
ledger/pool reconciliation, exact reversal links, and idempotent undo receipts.
The core suite also verifies restoration after the original lock expires and
repeated settlement/reversal cycles.

## Next work

1. Complete direct authenticated API/concurrency verification and host PIN setup.
2. Build host recovery controls, punter Kennel loop, ladder/projector additions, and deterministic demo equivalents. Squares remains the default and visual priority.
3. Add resilience/retry reconciliation, 60-player branch load rehearsal and cleanup, full browser flows, and branch site preview.
4. Demo, complete the approval gate, and only then promote the backend and deploy the completed experience to production.

This increment is approved for code integration. Phase 2 remains incomplete and is not ready for production backend promotion or the final product gate. The next-thread instructions are in `phase-3.md` on the handoff branch.
