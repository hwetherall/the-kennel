# Phase 3 — Studs v Spuds and Futures

Prepared 7 September 2026 for a new implementation thread.

## 1. Start here: the actual handoff state

Read this section before writing code. **Phase 2 is not yet a complete playable product.** Harry explicitly authorized merging its backend/API increment into `main` and creating this handoff branch. That code merge is not evidence that the Phase 2 phone demo, production backend promotion, or product gate happened.

- Phase 2 code merged through PR #3: https://github.com/hwetherall/the-kennel/pull/3.
- Merge commit on `main`: `197e496`.
- New code branch, already created from that merge: `codex/phase-3-studs-futures`.
- The existing selected backend is still **`phase-2-kennel`**, not a Phase 3 backend.
- Branch API: `https://bk8ptwjs-zww.function2.insforge.app/kennel-api`.
- Production project API base: `https://bk8ptwjs.us-west.insforge.app`.
- Production backend has not received the Phase 2 migrations or function changes in this handoff. Verify live state before assuming anything about deployment.
- `.env.local` points to the Phase 2 branch; `.env.phase-one.local` is an ignored backup. Never print, hardcode, or commit credentials. The CLI reads `.insforge/project.json`.

Read, in order:

1. `AGENTS.md` — InsForge project guidance and credential rules.
2. `claude.md` — product hierarchy, hard constraints, and original phase scope.
3. `phase-2-progress.md` — verified progress and remaining work.
4. `phase-2.md` — resolved Phase 2 contract, including approved recovery undo.
5. This file.
6. `context-phase2.md` only as historical context; its unresolved undo discussion is superseded by the approved rule in the plan and the applied recovery migration.
7. The migrations, edge function, shared types, client API, live snapshot hook, and punter/host/projector pages.

Do not recreate the existing code branch, replay already-applied migrations, or interpret a clean `main` as a completed Phase 2 gate. This thread should first close the Phase 2 prerequisites below, then implement Phase 3.

## 2. Phase 2 prerequisites

Already implemented:

- Exact integer reference settlement with tests committed before Kennel UI work.
- Courtesy and capped square grants; append-only ledger; one selection per market; stake increases; server-clock locking; idempotent settlement/refunds.
- Goal-driven Next Goal settlement and successor creation; behind-only score updates.
- Goal undo that unwinds later Next Goal settlements newest-first, refunds later markets, leaves already-void refunds intact, and restores the original market's original deadline.
- Quarter and overall profit ladders in server snapshots.
- Edge actions for betting and Next Goal host recovery, strict validation, safe error messages, and extended TypeScript contracts.

Still required before Phase 3 features:

- Authenticated HTTP mutation tests, simultaneous/retried bets, and branch host PIN setup.
- Client API methods for the new actions and snapshot reconciliation/retry handling.
- Host market controls; punter Kennel and Ladder views; projector market/ladder additions.
- Deterministic local demo behavior for the Kennel loop. The current demo only supplies empty market/ladder fields.
- Offline/reconnect verification, original-key retries, and prevention of stale responses overwriting newer state.
- A guarded 60-player load rehearsal through the real edge API, cleanup, and invariant checks.
- Complete phone/projector demo, preview, and all acceptance criteria in `phase-2.md`.

Use the existing Phase 2 backend to finish this work. Deliver it as a clearly scoped prerequisite PR and complete its demo/approval/production gate before opening Phase 3 markets. Keep this branch synchronized with the resulting `main`; do not silently combine unfinished Phase 2 acceptance with a claim that Phase 3 is complete.

Latest evidence at handoff:

- 50 local unit/component/edge tests and production build pass.
- Six existing Phase 1 phone/desktop browser tests pass; these are not Phase 2 betting flows.
- 17 deployed read-only edge checks pass; these do not prove authenticated HTTP mutation flows.
- Core database assertions and five recovery scenarios pass on the isolated branch, with fixture data rolled back.
- Advisor reports zero critical/warning findings and informational unused indexes. Its historical slow-query rule failed to run; an empty current slow-query list does not replace load testing.

Useful commands:

```sh
npm test
npm run build
npm run test:e2e
node scripts/verify-phase-two.mjs
node scripts/verify-phase-two.mjs --undo-recovery
node scripts/verify-phase-two-edge.mjs
```

The SQL verification scripts intentionally roll back through an exception. They accept only an exact structured error marker. Preserve this check: searching anywhere in CLI output can falsely pass when an error echoes the SQL. SQL arguments must follow `--` so leading comments cannot become CLI options.

## 3. Product scope and invariants

The Squares board remains the primary product, default punter tab, and largest content on the projector. Phase 3 adds:

1. **Studs v Spuds:** two or three configured pairs of AFL athletes per quarter, open during the break before the quarter they cover; back the higher quarter disposal total.
2. **Match-winner Future:** home or away, available before first bounce.
3. **Norm Smith Future:** a host-configured candidate list plus “Any other player”.

No Barks, streaks, transfers, new payment handling, sports feeds, scraping, or native accounts. Bones have no cash value. All prizes are non-monetary. Zeffy remains an outbound link and CSV source.

Preserve the server-authoritative ledger, pools, timing, and idempotency. One guest chooses one option per market and can only increase that selection while open. Rankings use settled net profit, never balance or turnover. Futures never count toward quarter prizes. Flooring dust is discarded and audited. A zero winning pool or an explicitly unresolved result voids/refunds; a one-sided winning pool returns stakes with zero profit.

Use the existing stack and dependencies. Ask before adding a dependency. Use the installed InsForge skills before changing SDK integration, migrations, functions, or backend configuration. Avoid restructuring unrelated Phase 1 code.

The following sections specify implementation defaults. Section 4 previously held an open product decision about cross-market undo; it is resolved and needs no confirmation, for the reason recorded there.

## 4. Resolved: spending a goal payout in another open market

**This section originally required a product decision. It no longer does.** It
was written on the assumption that Studs v Spuds opens at the start of a quarter
and locks five minutes in, overlapping live Next Goal markets. Harry corrected
that on 10 September: Studs is a **break** game. It opens during the break before
the quarter it covers, locks at that quarter's opening bounce, and stays closed
for the whole quarter. See `phase-3-undo-decision.md` for the full analysis and
the code citations behind what follows.

The feared scenario needed a goal payout to be spent in a market that was open at
the time of the goal. Under the corrected model that cannot happen, because
during a live unsealed quarter — the only window in which a goal payout can be
reversed — the only market that can accept a stake is Next Goal:

- Score events only exist while `period_status = 'live'`.
- Score undo refuses once `end_quarter` has written that quarter's
  `quarter_results` row, so it never reaches back past a siren.
- `place_bet` rejects any market that is not `open`, so a Studs market locked at
  the bounce takes nothing for the rest of the quarter.
- Studs for the next quarter has not opened, and both Futures locked at first
  bounce.

That is exactly the case the applied Phase 2 undo loop already unwinds, newest
first, before reversing the funding payout. **No ledger checkpoint, no
cross-type undo loop, and no additional migration for this.**

### The invariant that replaces it

> No market other than Next Goal is ever `open` while `period_status = 'live'`.

Enforce it in the database rather than by convention, folding in the lock-strategy
work section 8 already calls for:

- Markets carry a `lock_strategy` of `'deadline'` (Next Goal: a 90-second
  `locks_at`) or `'bounce'` (Studs and both Futures: locked by a game
  transition). `locks_at` is nullable for bounce-locked markets; do not invent a
  far-future date to satisfy a timed-market constraint.
- `start_quarter` locks every `open` bounce-locked market in the same transaction
  that sets `period_status = 'live'`, under the existing game lock.
- `place_bet` rejects a bounce-locked market whenever `period_status = 'live'`, so
  a stale `open` row can never accept a stake.
- Opening a bounce-locked market while `period_status = 'live'` is refused, so a
  host mis-tap cannot recreate the overlap.
- A behind undo never changes markets, as before.

Studs and Futures share one lock rule, tested once.

### The residual risk, deliberately deferred

Reversing an **already-paid Studs settlement** still hits
`ledger.balance_after CHECK (balance_after >= 0)` and aborts. The path: in a
break, the finished quarter's Studs pays out, the next quarter's matchups are
open in that same break, a guest stakes the payout, and only then does the host
find a disposal number was wrong and want to correct it downward.

Trigger and frequency are what changed. Score undo is guaranteed; a mis-typed
number discovered after an explicit preview-and-confirm step is rare. Keep this
deferred under section 5's existing rule that correcting an already-paid result
needs a separate audited recovery design. The draft/preview/confirm sequence in
section 5 is the mitigation, and an explicit void-and-refund path means the host
is never pushed into guessing a number to get past the screen. Do not quietly
weaken non-negative balances or disable score undo to get around it.

## 5. Studs v Spuds rules and data

### Configuration

Configure two or three matchups for each quarter, using stable athlete IDs and display names. The count per quarter is the host's choice and need not be the same across quarters. AFL athletes are not guest `players`; never join disposal records by nickname or treat an athlete as an authenticated app user.

A small `athletes` table and `studs_matchups` table are sufficient. Suggested matchup fields:

- `id`, `quarter` (1–4), `slot` ordering within the quarter, unique nullable `market_id`. `quarter` is **not** unique: a quarter carries several matchups. Make `(quarter, slot)` unique for a stable display order.
- `athlete_a_id`, `athlete_b_id`, with distinct-athlete constraint.
- `baseline_a`, `baseline_b`: cumulative totals at the previous quarter boundary.
- `ending_a`, `ending_b`: draft cumulative totals at this quarter's siren.
- Configuration/reading timestamps, finalized timestamp, and optional host note.

Store baseline and ending values used for the result so it can be reproduced. Require non-negative integers and ending totals at least as large as their baselines. Keep participant identity and baseline values immutable after opening; ending totals remain editable until explicit result confirmation.

Q1 baselines are zero. For Q2–Q4, obtain previous-quarter cumulative totals for the actual two selected athletes. Different quarters may use different pairs: subtracting the prior matchup's numbers is wrong. Copy an earlier confirmed boundary only when both the athlete identity and immediately preceding quarter match; otherwise the host supplies the baseline at the break. Do not substitute zero for unknown statistics.

Matchups are configured and priced independently. If one matchup's configuration or baselines are missing, open the others and show that this one did not open; if none are ready, start the quarter and Squares normally with no Studs market. Configuration must be complete before the break opens that quarter's matchups. A matchup that misses its break does not open at all, because a bounce-locked market can never open during live play.

### Opening and locking

- `end_quarter` opens the **next** quarter's ready matchups, in the same transaction that seals the finished quarter. Q1's matchups open pre-match instead, alongside the Futures.
- `start_quarter` **locks** that quarter's Studs markets atomically with the transition to `live`, under the shared game lock. They stay locked for the whole quarter.
- Copy athlete labels into immutable market option labels.
- Studs markets are `lock_strategy = 'bounce'` with a null `locks_at`. There is no five-minute window and no clock; the bounce is an event.
- Global pause blocks new/increased stakes without blocking scoring or the quarter transition.
- No special Studs stake cap unless explicitly configured. Continue enforcing any market's `max_stake` server-side.

### Results and corrections

The host enters cumulative game-to-date totals, and the server computes:

```text
quarter_a = ending_a - baseline_a
quarter_b = ending_b - baseline_b
```

Example: baselines 7 and 10, ending totals 13 and 15, gives quarter totals 6 and 5. Athlete A wins even though athlete B has the larger game total.

Provide a server-derived preview showing baselines, cumulative totals, quarter deltas, selected winner or tie, pools, and expected settlement audit. Editing a draft recalculates the preview without ledger mutations. Confirmation submits the exact totals; recompute and validate them inside the settlement transaction rather than trusting the browser's preview.

Equal quarter totals void/refund. Missing or unresolvable stats have an explicit host “Void and refund” path. No automatic guessed winner.

Corrections apply to draft readings before finalization and must not rewrite previously finalized quarters. Finalized results are immutable in the ordinary UI. Any later request to correct an already-paid result requires a separate audited recovery design, especially if those Bones have since been spent.

## 6. Siren handling: Squares first, prizes once stats are confirmed

Disposal lookup must not hold up the Squares siren result. Use a two-stage quarter close:

1. `end_quarter` immediately seals the score/Squares result, disables score undo for that quarter, voids/refunds unresolved Next Goal, and opens the next quarter's ready matchups. That quarter's own Studs markets are already locked, having locked at its opening bounce. While any of them is unresolved, mark the quarter ladder as awaiting its result.
2. Host confirms each matchup's totals or explicitly voids it. In one transaction settle/refund the market, and once the quarter's last matchup is resolved, finalize the quarter profit ladder and store the immutable standings for prizes.

Extend `quarter_results` with a ladder finalization state/timestamp. Existing Phase 2 quarter results are already final and must backfill as such. Keep the Squares result's `settled_at` separate from the ladder's finalization timestamp.

- No Studs market for the quarter: finalize the ladder at `end_quarter` as Phase 2 does.
- Any pending matchup: display provisional standings and “Awaiting Studs result”; do not announce prize winners yet. A quarter with three matchups finalizes once, after the third.
- Finalization can occur during the break or after the next quarter starts. Address the original quarter explicitly; never use the current quarter implicitly for delayed results.
- Starting the next quarter and host scoring must not require disposal lookup to finish. The next quarter's own matchup configuration and baseline readiness is checked independently. A still-pending result from an earlier quarter never blocks a bounce.
- Historical quarter results display their stored final standings, not a fresh query over the current quarter.
- Retried siren and result-confirmation requests must not double-refund, double-pay, or change finalized standings.

## 7. Futures rules

Configure exactly one match-winner Future and one Norm Smith Future for this event. Both have `counts_toward_quarter_prize = false`, `quarter = null`, and a default **200-Bone total stake cap per guest per market**. Increasing a position uses the remaining cap, not a fresh 200 allowance.

### Opening and first bounce

- Host opens Futures during `pre_match` only, after confirming their options and caps.
- Norm Smith must have at least one named candidate and exactly one “Any other player” option with a stable key, distinct from candidate IDs.
- Configuration can be edited in draft. Freeze options, labels, and caps when opened; no relabelling an option under existing stakes.
- Lock both Futures in the same transaction that starts Q1. Requests arriving after that transition are rejected under the shared game lock.
- First-bounce timing is an event transition, not a predicted kickoff timestamp. Do not invent a far-future lock date to satisfy a timed-market constraint.
- Add an explicit lock strategy of `deadline` versus `bounce`, adjust open-market constraints, and ensure both `place_bet` and effective snapshots enforce it. All paths must use the same server rule. Studs shares `bounce` with the Futures, per section 4, so this is one rule and not two: the Futures lock at the Q1 bounce and Studs at the bounce of the quarter it covers.
- Missed pre-match setup does not prevent Q1 starting. Do not open Futures after first bounce.

### Full time

Resolve Futures only after the host has sealed Q4 and the game is `final`, so score undo is already unavailable and no open prediction can spend these payouts.

- **Match winner:** offer a host confirmation using the server's final score to derive the winner. If final scores are equal, show a void/refund outcome; do not arbitrarily choose a team. Harry must confirm the actual match has finished, including any additional play, before sealing full time.
- **Norm Smith:** the host selects the official medal recipient from the configured candidates or “Any other player”. No feed or automatic lookup. Show the selected answer clearly before confirmation.
- If the result cannot be resolved, host voids/refunds with a reason. A winner with no backers also uses the existing zero-winning-pool void rule.
- Do not couple missing Norm Smith information to the ability to close Squares/Q4.
- Quarter prizes exclude Futures, including when settlement happens after Q4. Top Dog includes Futures profit.
- Show Top Dog as provisional until both Futures and any pending quarter predictions are settled or void. Only then announce the overall winner.
- Ordinary retries return the existing settlement; selecting a different winner after finalization must not silently rewrite payouts.

## 8. Database and API work

Use new migrations; preserve all existing migration files as applied history. Prefer constraints over client assumptions.

### Database changes

- Add athlete/matchup data, a relation from each Studs market to its configuration, and appropriate foreign-key indexes.
- Ensure at most one market per configured matchup, distinct athlete pairs within a quarter, and one of each Future per event. A quarter carries several Studs markets, so do not add a one-per-quarter constraint. Preserve the one-active-Next-Goal partial index; it must not forbid other market types.
- Extend market lock strategy and public effective-status calculation.
- No ledger or score metadata is needed for cross-market undo; section 4 explains why. Add instead the lock-strategy column and the guard that keeps bounce-locked markets from being open or staked while `period_status = 'live'`.
- Preserve `UNIQUE(market_id, player_id)`, composite bet-option ownership, audit guards, server-only ledger writes, and idempotency receipts scoped to action and actor.
- Freeze quarter ladder results separately from Squares results; backfill existing quarter results safely.
- Enable RLS and deny direct browser table/RPC access consistent with the existing edge boundary. Guest users remain referenced through the project's existing guest player model.
- Ensure all economic mutations share the established game/market/player lock strategy. Do not introduce a conflicting order from a disposal or configuration action.

The settlement arithmetic already supports more than two options. Reuse it. Generalize lifecycle checks and option keys rather than copying payout code for each feature.

### Edge actions (suggested contracts)

Keep `POST kennel-api`, `X-Player-Token`, `X-Host-Token`, and `Idempotency-Key`.

```text
configure_studs_matchup  { quarter, athleteAId, athleteBId, baselineA, baselineB }
configure_futures       { matchMaxStake, normSmithMaxStake, candidateIds }
open_futures            {}
preview_studs_result    { quarter, endingA, endingB }       # host read-only
finalize_studs_result   { quarter, endingA, endingB }       # host idempotent
void_studs_market      { quarter, reason }                 # host idempotent
settle_match_future     {}                                 # host idempotent; server derives winner
settle_norm_smith       { winningOptionId }                 # host idempotent
void_future            { marketId, reason }                # host idempotent
```

Use a small host-only athlete configuration surface or incorporate athlete creation into setup; avoid duplicate names creating duplicate identities unintentionally.

Extend existing `start_quarter`, `end_quarter`, `place_bet`, snapshots, and approved score undo. Restrict the existing generic Next Goal recovery action to Next Goal markets: a host must not bypass Studs/futures timing or finalization rules by sending their IDs to `settle_market` or `open_next_goal`.

Validate IDs, integer ranges, distinct athletes, option ownership, caps, phase/quarter status, and allowed transitions. Only deliberate product errors cross the edge boundary; never return raw SQL errors or tokens.

### Snapshot compatibility

Add plural market data while retaining the existing singular Next Goal fields during the transition:

- `markets` or `activeMarkets`: all displayable open/locked/pending predictions, including pre-match Futures.
- Player positions keyed by `marketId`; never reuse one `activeBet` across several cards.
- `lockStrategy`, authoritative timing, and explicit first-bounce/awaiting-result states.
- Host matchup baselines/draft totals, result preview, and pending finalizations.
- Per-quarter ladder finalization state and stored historical standings.
- An overall completion state for Top Dog.

Update `MarketSummary.type` from its current Next Goal-only literal, and `MarketOption.optionKey` from `TeamSide` to a validated per-type key. Do not assume two options or team labels in shared pool/card code. Keep full reconciliation from authoritative snapshots; server events request refreshes, not local balance deltas.

## 9. Interface work

Build on the completed Phase 2 interface; do not design around its current empty demo fields.

### Host

- Score/undo buttons remain first and largest.
- Setup: four matchup rows with athlete identities/baselines; Future candidate list and caps; a pre-bounce readiness summary.
- The siren reports which of the next quarter's matchups opened and why any were skipped. Quarter start reports that they have locked. Neither hides score entry.
- Siren immediately shows the Squares winner. Pending Studs results are a separate clear task.
- Cumulative input labels, visible baseline and computed quarter delta, a result preview, then explicit confirmation or void.
- A queue of unresolved quarter/Future results, so the host can finish older-quarter stats correctly.
- Undo confirmation discloses the Next Goal markets that will be refunded. Per section 4 no other market type can be affected.

### Punter

- Squares stays the default tab; Kennel groups live quarter predictions and pre-match Futures.
- Each market has its own pool, position, selection lock, remaining cap, request state, and retry key.
- The Kennel tab follows the game phase, because Studs and Next Goal are never open together. During play, Next Goal is prominent and the quarter's Studs markets show “Locked until the siren”. During a break, the next quarter's matchups are prominent and show that they lock at the bounce. Futures show “Locks at first bounce” before Q1 and “Awaiting full-time result” after.
- Multi-option Norm Smith pools remain readable around 360 px; do not squeeze candidates into a two-team bar.
- State clearly that Futures count toward Top Dog only. Show signed net profit and distinguish refunds from positive profit.
- Finalized quarter standings and provisional/final Top Dog are visibly distinct.

### Projector and accessibility

Keep score/Squares dominant. Show whichever game is live — Next Goal during play, the coming quarter's Studs matchups during a break — plus a compact summary of the current quarter's locked Studs positions and the quarter top five. Display Future results and final Top Dog when relevant rather than crowding every market onto the grid all night.

Preserve large touch targets, keyboard focus, labels/live regions, reduced motion, offline state, and information conveyed through text as well as color.

## 10. Verification before approval

Retain every Phase 1/2 regression, especially the five goal-undo scenarios. Add tests that prove behavior rather than mirroring implementation.

### Database / edge integration

- Different athletes across quarters use the correct identity-specific baseline; swapped matchup sides do not swap historical totals.
- Server computes the canonical 6-versus-5 example; negative/decreasing/fractional inputs fail atomically.
- Tied disposals, missing stats, no winning backers, and one-sided pools return the correct refunds/profit.
- Draft corrections change no ledger; finalized earlier quarters remain immutable.
- Siren settles Squares immediately while Studs stats are pending; delayed quarter finalization uses the addressed quarter and freezes its own ladder exactly once.
- An unconfigured matchup cannot block start/scoring/end-quarter.
- Two Futures and several Studs markets coexist pre-match; one-active-Next-Goal still holds and does not forbid them.
- No bounce-locked market can be opened or staked while `period_status = 'live'`, including with a forged client time or a stale `open` row. `start_quarter` locks every one of them atomically.
- A quarter carries several matchups that open, lock, and resolve independently, and its ladder finalizes exactly once after the last of them.
- Concurrent first-bounce and Future stake requests serialize correctly; no post-bounce request succeeds, even with forged client time.
- Future cap applies to total stake across increases. Neither Future affects quarter profit, both affect Top Dog.
- Norm Smith selected candidate, “Any other player”, zero-winning-pool, and explicit void work with more than two options and audited dust.
- Generic recovery endpoints cannot bypass type-specific restrictions.
- The five existing goal-undo scenarios still pass unchanged. Per section 4 there is no cross-market spending case to test, because no other market can accept a stake during live play; assert that invariant directly rather than testing a policy for it.
- All balances equal ledger sums; pools equal accepted stakes; settlement payouts plus dust conserve the pool; reversals are exact and unique.
- Advisor/RLS checks show no public economic mutation path or unresolved introduced warning/critical finding. Report checks that did not run.

### Browser and operational rehearsal

- Host configures all matchups/Futures, guests stake pre-bounce, Q1 locks Futures, and quarter markets appear correctly.
- Guests hold separate positions in simultaneous markets and increase only their chosen option.
- Host enters a goal, exercises goal undo, and all devices reconcile. Confirm that the quarter's Studs markets are visibly locked throughout and are untouched by the undo.
- Siren displays Squares immediately; host corrects a draft reading and finalizes the quarter prize once.
- Q4 closes, Match winner and Norm Smith settle, and Top Dog becomes final only when all results are resolved.
- Pause/offline/reconnect and uncertain original-key retries do not duplicate stakes or overwrite newer snapshots.
- Phone, laptop host, projector, print backup, and 360 px overflow checks pass.
- Repeat the 60-player branch-only rehearsal with simultaneous market types and mixed snapshots; verify invariants and clean up synthetic data.

## 11. Delivery sequence and isolation

1. Confirm the existing branch, actual backend link, environment, and current progress; run the baseline checks.
2. Finish and gate Phase 2 as described in section 2. Ask only for genuinely missing setup or required final promotion approval; earlier authorization persists.
3. Section 4 is resolved and blocks nothing; `phase-3-undo-decision.md` records the analysis. No approval is outstanding for it.
4. After Phase 2 is present in the production parent, create a new InsForge schema-only backend branch `phase-3-studs-futures`. Do not branch from the still-Phase-1 parent and assume Phase 2 objects exist. Verify the supported CLI branch workflow rather than assuming nested branches are supported.
5. Point ignored local environment values to that backend, restart the dev server, and verify the complete Phase 2 baseline there. Seed only guarded non-production rehearsal data.
6. Add constraints/schema/transactions and test cases before new UI. Prove the section 4 invariant and bounce locking first: no bounce-locked market open or stakeable during live play, and `start_quarter` locking them atomically.
7. Extend the edge API and snapshot contracts; verify authenticated flows directly.
8. Build host configuration/results, then punter market cards and ladder states, then projector additions.
9. Add deterministic demo cases, full browser coverage, failure/retry checks, and the mixed-market load rehearsal.
10. Create/update `phase-3-progress.md` with applied migrations, exact evidence, limitations, and remaining work. Keep the PR title/body aligned with the implemented scope.
11. Deploy a branch preview, demo phone/host/projector, run backend merge dry-run, inspect the generated SQL, and obtain final production promotion approval.
12. Only then merge the backend, deploy the production edge function and site in a compatible order, merge the code PR, and live-smoke-test. Record actual URLs and commits; do not invent a preview URL.

## 12. Acceptance gate and human inputs

Phase 3 is ready only when:

- [ ] Phase 2's remaining work and gate are complete.
- [ ] The invariant replacing section 4's undo rule is implemented and verified: no market other than Next Goal is ever open while play is live.
- [ ] Every configured Studs matchup, two or three per quarter, is identity-correct and opens in the preceding break, locks at the bounce, and resolves safely, including ties and missing stats.
- [ ] Squares sirens and score controls remain reliable while disposal results are pending.
- [ ] Historical quarter prizes finalize once and exclude both Futures.
- [ ] Both Futures lock atomically at first bounce, enforce caps, and resolve correctly after full time.
- [ ] Norm Smith always includes “Any other player”.
- [ ] Top Dog includes all settled profit and is not announced as final prematurely.
- [ ] All economic mutations remain server-side, idempotent, audited, and protected.
- [ ] Automated, mixed-market load, phone/projector, offline, and live promotion checks pass with limitations recorded.
- [ ] The phase is demoed, approved, merged, deployed, and live-smoke-tested.

Harry supplies the matchups, two or three per quarter, plus Norm Smith candidates, sponsor labels, and actual cumulative disposal readings once known. Use clearly labelled synthetic athletes only in demos/test branches. Ask for missing real configuration when needed; never guess the finalist teams or award recipient.

The new thread may begin with: “Read phase-3.md and the linked handoff files, verify the actual Phase 2 state, then work through the prerequisites and Phase 3 plan in order.”
