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

1. **Studs v Spuds:** one configured pair of AFL athletes per quarter; back the higher quarter disposal total.
2. **Match-winner Future:** home or away, available before first bounce.
3. **Norm Smith Future:** a host-configured candidate list plus “Any other player”.

No Barks, streaks, transfers, new payment handling, sports feeds, scraping, or native accounts. Bones have no cash value. All prizes are non-monetary. Zeffy remains an outbound link and CSV source.

Preserve the server-authoritative ledger, pools, timing, and idempotency. One guest chooses one option per market and can only increase that selection while open. Rankings use settled net profit, never balance or turnover. Futures never count toward quarter prizes. Flooring dust is discarded and audited. A zero winning pool or an explicitly unresolved result voids/refunds; a one-sided winning pool returns stakes with zero profit.

Use the existing stack and dependencies. Ask before adding a dependency. Use the installed InsForge skills before changing SDK integration, migrations, functions, or backend configuration. Avoid restructuring unrelated Phase 1 code.

The following sections specify implementation defaults. The cross-market undo policy in section 4 is a new product decision and must be confirmed before dependent implementation; it is not part of Harry's earlier Next Goal-only approval.

## 4. Required design decision: spending a goal payout in another open market

The Phase 2 undo fix covers later **Next Goal** markets. Studs v Spuds will be open for five minutes, overlapping Next Goal markets. That introduces a different dependency:

1. A goal pays a guest 1,500 Bones.
2. The guest stakes those Bones on the already-open Studs market, whose market sequence may precede the goal.
3. The host undoes the goal.
4. Refunding later Next Goal markets cannot recover the Bones in that Studs stake, so reversal would make the balance negative.

This happens even if Studs has never settled. Restricting its settlement until the siren alone does not solve it. Do not expose concurrent markets until this case has a verified solution.

**Recommended policy for Harry to confirm:** when undo finds post-goal stakes in an unresolved Studs market, void and refund that entire affected Studs market before reversing the goal payout. Keep earlier unaffected markets intact. Show the host the affected prediction in the undo confirmation and show guests the refund reason. Do not silently reopen or extend its deadline. This is intentionally a rare score-correction consequence rather than a second wallet or partial-stake accounting system.

To implement that recommendation if approved:

- Record a ledger sequence checkpoint on each goal after its settlement and before returning the mutation. Use the existing shared game lock to establish ordering; do not infer order from client timestamps or market creation sequence alone.
- Detect unreversed negative stake rows after that checkpoint in other unresolved markets in the same quarter.
- Refund/void affected Studs markets and unwind later Next Goal markets before reversing the original goal credits. All operations remain one transaction under the same lock order.
- Already-void markets keep their refunds. Original-key retries do not create more credits.
- A behind undo never changes markets.
- Do not permit Studs settlement while that quarter's scores remain undoable. Futures lock at first bounce and settle only after full time.
- Test already-open Studs markets with pre-goal stakes, post-goal increases, and later Next Goal spending of related refunds.

If Harry prefers preserving unaffected stakes within the Studs market, design a separate, audited stake-reversal mechanism and its selection semantics before coding it. Do not quietly weaken non-negative balances or disable score undo.

## 5. Studs v Spuds rules and data

### Configuration

Configure four matchups, one for each quarter, using stable athlete IDs and display names. AFL athletes are not guest `players`; never join disposal records by nickname or treat an athlete as an authenticated app user.

A small `athletes` table and `studs_matchups` table are sufficient. Suggested matchup fields:

- `id`, unique `quarter` (1–4), unique nullable `market_id`.
- `athlete_a_id`, `athlete_b_id`, with distinct-athlete constraint.
- `baseline_a`, `baseline_b`: cumulative totals at the previous quarter boundary.
- `ending_a`, `ending_b`: draft cumulative totals at this quarter's siren.
- Configuration/reading timestamps, finalized timestamp, and optional host note.

Store baseline and ending values used for the result so it can be reproduced. Require non-negative integers and ending totals at least as large as their baselines. Keep participant identity and baseline values immutable after opening; ending totals remain editable until explicit result confirmation.

Q1 baselines are zero. For Q2–Q4, obtain previous-quarter cumulative totals for the actual two selected athletes. Different quarters may use different pairs: subtracting the prior matchup's numbers is wrong. Copy an earlier confirmed boundary only when both the athlete identity and immediately preceding quarter match; otherwise the host supplies the baseline at the break. Do not substitute zero for unknown statistics.

If configuration or baselines are missing, start the match quarter and Squares normally, while showing that Studs did not open. Require configuration before the quarter starts; do not open it late after guests have seen part of that quarter's play.

### Opening and locking

- `start_quarter` opens that quarter's configured Studs market atomically with the normal Next Goal setup when its configuration is ready.
- Copy athlete labels into immutable market option labels.
- Set `locks_at` from the authoritative quarter-start instant plus five minutes.
- A timed-open market becomes effectively locked using server time even if stored status is still `open`.
- Global pause blocks new/increased stakes without extending the lock time or blocking scoring.
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

1. `end_quarter` immediately seals the score/Squares result and disables score undo for that quarter, voids/refunds unresolved Next Goal, and locks any Studs market. If Studs remains unresolved, mark the quarter ladder as awaiting its result.
2. Host confirms Studs totals or explicitly voids it. In one transaction settle/refund the market, finalize the quarter profit ladder, and store the immutable standings for prizes.

Extend `quarter_results` with a ladder finalization state/timestamp. Existing Phase 2 quarter results are already final and must backfill as such. Keep the Squares result's `settled_at` separate from the ladder's finalization timestamp.

- No Studs market, or one already voided by score correction: finalize the ladder at `end_quarter` as Phase 2 does.
- Pending Studs: display provisional standings and “Awaiting Studs result”; do not announce prize winners yet.
- Finalization can occur during the break or after the next quarter starts. Address the original quarter explicitly; never use the current quarter implicitly for delayed results.
- Starting the next quarter and host scoring must not require disposal lookup to finish. Its own Studs configuration/baseline readiness is checked independently.
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
- Add an explicit lock strategy such as `deadline` versus `first_bounce`, adjust open-market constraints, and ensure both `place_bet` and effective snapshots enforce it. All paths must use the same server rule.
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
- Ensure at most one Studs market per quarter and one of each Future per event. Preserve the one-active-Next-Goal partial index; it must not forbid other market types.
- Extend market lock strategy and public effective-status calculation.
- Extend ledger/score metadata only as needed for the approved cross-market undo policy.
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
- Quarter start reports whether Studs opened or why it was skipped, without hiding score entry.
- Siren immediately shows the Squares winner. Pending Studs results are a separate clear task.
- Cumulative input labels, visible baseline and computed quarter delta, a result preview, then explicit confirmation or void.
- A queue of unresolved quarter/Future results, so the host can finish older-quarter stats correctly.
- Undo confirmation must disclose any additional predictions that will be refunded under the confirmed cross-market policy.

### Punter

- Squares stays the default tab; Kennel groups live quarter predictions and pre-match Futures.
- Each market has its own pool, position, selection lock, remaining cap, request state, and retry key.
- Next Goal stays prominent during play; Futures show “Locks at first bounce” before Q1 and “Awaiting full-time result” after lock.
- Multi-option Norm Smith pools remain readable around 360 px; do not squeeze candidates into a two-team bar.
- State clearly that Futures count toward Top Dog only. Show signed net profit and distinguish refunds from positive profit.
- Finalized quarter standings and provisional/final Top Dog are visibly distinct.

### Projector and accessibility

Keep score/Squares dominant. Show Next Goal, a compact current-quarter Studs summary, and quarter top five. Display Future results and final Top Dog when relevant rather than crowding every market onto the grid all night.

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
- Two Futures can coexist with Next Goal and Studs; one-active-Next-Goal still holds.
- Concurrent first-bounce and Future stake requests serialize correctly; no post-bounce request succeeds, even with forged client time.
- Future cap applies to total stake across increases. Neither Future affects quarter profit, both affect Top Dog.
- Norm Smith selected candidate, “Any other player”, zero-winning-pool, and explicit void work with more than two options and audited dust.
- Generic recovery endpoints cannot bypass type-specific restrictions.
- Cross-market goal-payout spending and undo pass under the policy confirmed in section 4. Include stakes on older-created Studs markets, increases to existing positions, replayed requests, and later Next Goal spending.
- All balances equal ledger sums; pools equal accepted stakes; settlement payouts plus dust conserve the pool; reversals are exact and unique.
- Advisor/RLS checks show no public economic mutation path or unresolved introduced warning/critical finding. Report checks that did not run.

### Browser and operational rehearsal

- Host configures all matchups/Futures, guests stake pre-bounce, Q1 locks Futures, and quarter markets appear correctly.
- Guests hold separate positions in simultaneous markets and increase only their chosen option.
- Host enters a goal, exercises the approved cross-market undo, and all devices reconcile.
- Siren displays Squares immediately; host corrects a draft reading and finalizes the quarter prize once.
- Q4 closes, Match winner and Norm Smith settle, and Top Dog becomes final only when all results are resolved.
- Pause/offline/reconnect and uncertain original-key retries do not duplicate stakes or overwrite newer snapshots.
- Phone, laptop host, projector, print backup, and 360 px overflow checks pass.
- Repeat the 60-player branch-only rehearsal with simultaneous market types and mixed snapshots; verify invariants and clean up synthetic data.

## 11. Delivery sequence and isolation

1. Confirm the existing branch, actual backend link, environment, and current progress; run the baseline checks.
2. Finish and gate Phase 2 as described in section 2. Ask only for genuinely missing setup or required final promotion approval; earlier authorization persists.
3. Before Phase 3 dependent code, present the concrete cross-market undo proposal from section 4 to Harry and record the chosen behavior here.
4. After Phase 2 is present in the production parent, create a new InsForge schema-only backend branch `phase-3-studs-futures`. Do not branch from the still-Phase-1 parent and assume Phase 2 objects exist. Verify the supported CLI branch workflow rather than assuming nested branches are supported.
5. Point ignored local environment values to that backend, restart the dev server, and verify the complete Phase 2 baseline there. Seed only guarded non-production rehearsal data.
6. Add constraints/schema/transactions and test cases before new UI. Prove cross-market undo and first-bounce locking first.
7. Extend the edge API and snapshot contracts; verify authenticated flows directly.
8. Build host configuration/results, then punter market cards and ladder states, then projector additions.
9. Add deterministic demo cases, full browser coverage, failure/retry checks, and the mixed-market load rehearsal.
10. Create/update `phase-3-progress.md` with applied migrations, exact evidence, limitations, and remaining work. Keep the PR title/body aligned with the implemented scope.
11. Deploy a branch preview, demo phone/host/projector, run backend merge dry-run, inspect the generated SQL, and obtain final production promotion approval.
12. Only then merge the backend, deploy the production edge function and site in a compatible order, merge the code PR, and live-smoke-test. Record actual URLs and commits; do not invent a preview URL.

## 12. Acceptance gate and human inputs

Phase 3 is ready only when:

- [ ] Phase 2's remaining work and gate are complete.
- [ ] The new cross-market undo rule is explicitly confirmed, implemented, and verified.
- [ ] Four identity-correct Studs matchups open/lock/resolve safely, including ties and missing stats.
- [ ] Squares sirens and score controls remain reliable while disposal results are pending.
- [ ] Historical quarter prizes finalize once and exclude both Futures.
- [ ] Both Futures lock atomically at first bounce, enforce caps, and resolve correctly after full time.
- [ ] Norm Smith always includes “Any other player”.
- [ ] Top Dog includes all settled profit and is not announced as final prematurely.
- [ ] All economic mutations remain server-side, idempotent, audited, and protected.
- [ ] Automated, mixed-market load, phone/projector, offline, and live promotion checks pass with limitations recorded.
- [ ] The phase is demoed, approved, merged, deployed, and live-smoke-tested.

Harry supplies the four matchups, Norm Smith candidates, sponsor labels, and actual cumulative disposal readings once known. Use clearly labelled synthetic athletes only in demos/test branches. Ask for missing real configuration when needed; never guess the finalist teams or award recipient.

The new thread may begin with: “Read phase-3.md and the linked handoff files, verify the actual Phase 2 state, then work through the prerequisites and Phase 3 plan in order.”
