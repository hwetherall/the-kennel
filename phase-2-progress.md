# Phase 2 implementation progress

Updated 7 September 2026. The product contract and acceptance criteria remain in [phase-2.md](phase-2.md).

## Completed: isolation and executable settlement specification

- Code branch: `codex/phase-2-kennel`, created from verified `main` at `66fe8e1`.
- InsForge backend: `phase-2-kennel`, schema-only, ready, selected in the local CLI.
- Branch API: `https://bk8ptwjs-zww.function2.insforge.app/kennel-api`.
- The unchanged Phase 1 function is deployed to the branch. Synthetic event configuration and 100 unassigned squares supply its empty baseline.
- Ignored `.env.local` points to the branch. The prior local configuration is backed up in ignored `.env.phase-one.local`. Browser polling uses no API key.
- Settlement tests and the pure reference implementation were committed before any Kennel UI work (`0b5142f`).
- Production has not received Phase 2 changes. No dependencies were added.

The reference implementation is for tests and documentation only. It returns settlement audit fields and credit intents, using exact integer arithmetic. Persisted settlement returns no further credits. It does **not** implement database transactions, balance mutation, locking, or request receipts; those need separate integration tests.

Coverage includes the canonical payout, no-winning-backer refunds, one-sided pools, a single backer, empty pools, uneven shares and dust, repeated settlement/refunds, integer overflow, invalid options/stakes, and conservation across 3,600 pool combinations.

## Verification

- Phase 1 baseline: 5 unit/component tests, 6 phone/desktop browser tests, and production build passed.
- With the settlement specification: 25 unit/component tests and production build passed.
- Branch API smoke check returns a complete snapshot with 100 squares.
- The build still prints the existing InsForge SDK browser `crypto` externalization warning.

## Local branch setup

After selecting the ready `phase-2-kennel` backend and deploying `functions/kennel-api.ts`, run:

```sh
node scripts/setup-phase-two.mjs
npm run dev
```

The setup script verifies the linked backend against the CLI's branch list, refuses the production parent, inserts only missing baseline rows, verifies the public snapshot, and updates ignored local environment settings. Restart an existing dev server after running it. Host PIN setup and authenticated backend verification remain pending.

## Next work

Continue at step 3 in the plan: the coherent migration for grants, ledger, markets, bets, settlements, ladders, and reversible score integration. Apply it only to the backend branch and verify transaction invariants before extending the edge API and UI.

Still pending: the Phase 2 database/API/UI, backend integration and security checks, resilience and load rehearsal, site preview, demo, and approval gate. This increment does not make Phase 2 ready for approval or production merge.
