# Next steps — handoff for a new thread

Written 10 September 2026. Fifteen days to the event (Friday 25 September 2026,
~10:30pm MDT). **Phase 2 is live in production.** Phase 3 has not started.

## 1. Start here: the actual state

Read this section before touching anything. Several things in this repo's older
planning documents are now wrong, and several things that look undone are done.

### Code

- `main` is at `e867c8b` (merge of PR #4). Phase 1 and Phase 2 are both merged.
- **There is an unmerged branch with three commits and no PR yet:
  `claude/phase-3-studs-futures`, head `0110d05`.** It is pushed. Do not
  recreate it, and do not duplicate its work. It contains the production
  promotion record, one addition to the human-task checklist, and a real code
  change: the branch-setup and verification scripts were generalised so they run
  on any development branch instead of only `phase-2-kennel`. The rehearsal
  below depends on that change. Either open a small PR for it or fold it into the
  Phase 3 PR — decide, don't leave it dangling.
- 5 migrations, all applied and immutable history. 64 unit/component/edge tests
  in 8 files. 10 Playwright flows.

### Production — live, and holding real state

| | |
|---|---|
| Site | <https://bk8ptwjs.insforge.site> (deployment `d1fff339-6c79-4bb8-8f81-3846bf39a849`) |
| API base | <https://bk8ptwjs.us-west.insforge.app> |
| Edge | <https://bk8ptwjs.function2.insforge.app/kennel-api> |
| Project | `51939a47-4e6a-4296-b74d-966852c9da01`, app key `bk8ptwjs` |

Promoted on 10 September with Harry's explicit approval. The backend merge
applied 23 additions and 13 modifications with zero conflicts, and carried the
`kennel-api` edge function itself as a `[DATA] edge_function` row — there is no
separate function deploy step for a branch merge. The site was a **first ever**
deployment; before it the URL returned Vercel `DEPLOYMENT_NOT_FOUND`.

Production data, as of this handoff:

- One real player, `Haz`, 0 squares, balance 1000, with one `courtesy_grant`
  ledger row. Harry created it by joining the live site. **It cannot be deleted**
  — the `ledger_immutable` trigger makes the ledger append-only. Decide before
  the night whether `Haz` stays as a genuine guest or production is reset.
- Teams are still the placeholders `Home` / `Away`.
- Grid digits are already randomly assigned: rows `[7,2,9,4,0,6,1,8,3,5]`,
  columns `[3,8,1,6,0,5,9,2,7,4]`.
- 0 squares purchases; the Zeffy CSV import has not been run. `pre_match`.

**Never run a rehearsal, load test, or seeding script against production.** The
guarded scripts already refuse app key `bk8ptwjs`; keep that guard.

Two restore points exist: manual `adfde23d-73af-4028-9110-47633fc5ec0f`
(`post-phase-2-promotion`) and scheduled `e4d1631d-d93f-4508-a8f1-ce85ccf16f53`
(2:00 AM 10 September, pre-merge).

### Development backend — created, seeded, verified

`phase-3-studs-futures`, project `5646765f-bcf4-48e7-a22f-0699ce4bd662`, app key
`bk8ptwjs-yw5`, schema-only, `ready`, and it is the currently linked project.
`.env.local` points at it, so local scripts and the dev server cannot reach
production.

- API base <https://bk8ptwjs-yw5.us-west.insforge.app>
- Edge <https://bk8ptwjs-yw5.function2.insforge.app/kennel-api>
- Its T0 is the Phase 2 parent, so `branch reset` returns a pristine Phase 2 base
  and reuses the slot. That is how to get a clean base for Phase 3 after the
  rehearsal.
- Baseline verified there: both rolled-back database suites, 17 read-only edge
  checks, 64 unit tests, production build.
- `kennel-api` is deployed on it. It has **no preview site** and **no
  `HOST_PIN`** — see section 4.

`phase-2-kennel` (`bk8ptwjs-zww`) is retained in `merged` state as a reference.
`phase-1-squares` was deleted to free a slot.

**Branch slots are capped at 2 per parent.** `branch create` fails with
`Per-parent quota: max 2 branches per parent`, and merged branches still hold a
slot. `branch reset` restores a branch's *own* original dump, not the parent's
current state, so an old branch cannot be reset into a current one.

## 2. Read in order

1. `AGENTS.md` — InsForge guidance and credential rules.
2. `claude.md` — product hierarchy and the hard constraints. Authoritative.
3. `phase-3-undo-decision.md` — why phase-3.md section 4 needs no decision.
4. `phase-3.md` — the Phase 3 contract, as corrected.
5. `phase-3-progress.md` — verified state and outstanding work.
6. `phase-2.md`, `phase-2-progress.md` — Phase 2 contract and evidence.
7. The migrations, edge function, `src/types.ts`, `src/lib/api.ts`, the live
   snapshot hook, and the punter/host/projector pages.

`context-phase2.md` is historical only.

## 3. Corrections that must not be reverted

Harry corrected two product facts on 10 September. Older text elsewhere may
still contradict them; the specs were updated and should win.

1. **Studs v Spuds is a break game.** It opens during the break *before* the
   quarter it covers (pre-match for Q1), locks at that quarter's opening bounce
   by event and not by a clock, stays closed all quarter, and is reconciled at
   the siren, when the next quarter's matchups open. It is **not** open for the
   first five minutes of play. Next Goal is the continuous in-play game.
2. **A quarter carries two or three matchups**, count at the host's discretion —
   not one. `quarter` is not unique on `studs_matchups`; use `(quarter, slot)`.

Consequence: **phase-3.md section 4 is resolved and needs no product decision.**
During a live unsealed quarter — the only window where a goal payout can be
reversed — the only market that can accept a stake is Next Goal, which the
applied Phase 2 undo loop already unwinds. Do not build a ledger checkpoint or a
cross-type undo loop.

What replaces it, and must be implemented and tested:

> No market other than Next Goal is ever `open` while `period_status = 'live'`.

Enforce it in the database: a `lock_strategy` of `'deadline'` (Next Goal, 90s
`locks_at`) versus `'bounce'` (Studs and both Futures, nullable `locks_at`);
`start_quarter` locking every open bounce-locked market in the same transaction;
`place_bet` rejecting a bounce-locked market whenever play is live; and opening a
bounce-locked market during live play being refused.

The residual risk — reversing an already-paid Studs settlement after a mis-typed
disposal number — stays deferred under section 5, mitigated by the
draft/preview/confirm sequence. Do not weaken the non-negative balance guard or
disable score undo.

3. The scripts' guards were deliberately generalised. Keep the
   `parent_project_id` requirement and the `appkey !== 'bk8ptwjs'` refusal, which
   are what actually protect production. Do not reintroduce a literal branch
   name.

## 4. Blocked on Harry

This session's sandbox classifier refused to write a secret to a file or pass
environment values into a deploy. These are his to run, and the branch is the
currently linked project:

```sh
npx -y @insforge/cli secrets add HOST_PIN <pin>
npx -y @insforge/cli deployments env set VITE_INSFORGE_URL https://bk8ptwjs-yw5.us-west.insforge.app
npx -y @insforge/cli deployments deploy .
```

The first is non-optional: the host console cannot authenticate without it, and
`HOST_PIN` is a per-project secret that a branch does not inherit. The second and
third give the branch a preview site, which a rehearsal needs so guests can join
from phones.

Optional but a real fidelity gap: without `VITE_INSFORGE_ANON_KEY` the client
falls back to polling, while production has realtime. Read `ANON_KEY`, set it as
`VITE_INSFORGE_ANON_KEY` on the deployment, redeploy.

Still needed from Harry generally: the Zeffy CSV, the finalist team names, the
Studs matchups and their cumulative disposal baselines, the Norm Smith candidate
list, and sponsor labels. Use clearly labelled synthetic athletes until then;
never guess finalists or an award recipient.

## 5. Priority 1 — dress rehearsal against a real finals match

Harry's decision, and it outranks Phase 3 for now. Rehearse the live loop
against a real match rather than synthetic data, prioritising the **Semi
Finals**. Assuming the usual four-week AFL finals structure back from the 26
September Grand Final, those fall around **11–12 September**, i.e. within a day
or two of this handoff. Prelims around 18–19 September. **Confirm against the
published fixture — those dates are inferred, not verified.**

Phase 2 is already live and is the whole risky core: squares board, host score
entry, the Next Goal cycle, the ladder. Phase 3 will not exist by the Semi
Finals and is not needed for it.

- Run it on the **branch preview, never production**, so rehearsal guests,
  stakes and payouts do not land permanently in production's append-only ledger.
- **Land no Phase 3 migrations before the rehearsal**, so it exercises exactly
  the code on `main` and in production.
- Before starting: set the real team names in the host console, and shuffle the
  grid. The setup script seeds `grid_config` with digits in natural `0`–`9`
  order, which makes the live square trivially predictable; the console has a
  shuffle control.
- Watch for the known connection ceiling: the platform caps Postgres at 30
  connections regardless of instance size. The client and the rehearsal script
  already do bounded same-identity retries with the original idempotency key.
- Afterwards, write up what broke, then `branch reset phase-3-studs-futures` to
  get a clean Phase 2 base before Phase 3 migrations.

## 6. Priority 2 — Phase 3

Follow `phase-3.md` sections 5 to 10, with the section 3 corrections above.
Order matters:

1. Migrations and tests **before any UI**: `athletes` and `studs_matchups` with
   `(quarter, slot)`, the market/matchup relation, `lock_strategy`, the
   bounce-locking guard, and quarter-ladder finalization split from the Squares
   `settled_at`. Prove the section 4 invariant and bounce locking first.
2. Edge actions and snapshot contracts, verified over authenticated HTTP.
3. Type widening — these are the known starting points:
   - `src/types.ts:10` — `MarketOption.optionKey` is `TeamSide`; needs a
     validated per-type key.
   - `src/types.ts:26` — `MarketSummary.type` is the literal `'next_goal'`.
   - `src/types.ts:143` — `PlayerSnapshot.activeBet` is a single position; needs
     positions keyed by `marketId`. Never reuse one across market cards.
   - Do not assume two options or team labels in shared pool/card code; Norm
     Smith has many options and must stay readable at 360px.
4. Host configuration and results, then punter market cards and ladder states,
   then projector additions.
5. Deterministic demo cases, browser coverage, failure/retry checks, and a
   mixed-market load rehearsal.
6. Update `phase-3-progress.md` with applied migrations and exact evidence, then
   preview, demo, and promotion approval.

## 7. Commands

```sh
npm test
npm run build
npm run test:e2e
node scripts/setup-phase-two.mjs          # seeds a fresh dev branch, repoints .env.local
node scripts/verify-phase-two.mjs
node scripts/verify-phase-two.mjs --undo-recovery
node scripts/verify-phase-two-edge.mjs
node scripts/rehearse-phase-two.mjs --run | --smoke | --cleanup
```

The SQL verification scripts roll back through an exception and accept only an
exact structured error marker. Preserve that check: searching anywhere in CLI
output can falsely pass when an error echoes the SQL. SQL arguments must follow
`--` so leading comments cannot become CLI options.

Use `npx -y @insforge/cli` — keep npx's `-y`, and there is no global `insforge`
binary. Load the `insforge-cli` skill before backend or migration work, per
`AGENTS.md`.

## 8. Known state of checks

- Advisor, most recent scan: 0 critical, 0 warning, **7** informational
  unused-index findings. Older documents say 3; 7 is current.
  `pg_stat_statements` is unavailable, so the historical slow-query rule does not
  run. An empty slow-query list is not a substitute for load testing.
- Production build emits a known `crypto` externalization warning from the
  InsForge SDK.
- The five goal-undo recovery scenarios must keep passing, unchanged, through
  all Phase 3 work.

## 9. Do not

- Re-run the Phase 2 promotion, or merge a backend branch without a `--dry-run`
  first and a read of the generated SQL.
- Write to production: no joins, no seeding, no rehearsal, no load test.
- Recreate `claude/phase-3-studs-futures` or replay applied migrations.
- Build a cross-market undo policy. Section 4 is resolved.
- Add a dependency, touch payment handling, or add a live sports feed. All
  scores and stats are host-entered, deliberately.

## 10. Suggested opening line for the new thread

> Read `new-prompt.md` and the handoff files it lists, verify the live state
> yourself, then work through the dress rehearsal and Phase 3 in that order.
