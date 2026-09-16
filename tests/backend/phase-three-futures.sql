-- Phase 3, step 3 assertions: the two Futures, end to end.
--
-- Run by scripts/verify-phase-three.mjs, which prepends all three unapplied
-- Phase 3 migrations so the whole thing rolls back.
--
-- Drives the real host functions rather than hand-writing rows, so the timing
-- rules are proved the way the console will actually hit them.
DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  a_hash text := repeat('a', 32) || suffix;
  b_hash text := repeat('b', 32) || suffix;
  c_hash text := repeat('c', 32) || suffix;
  a uuid; b uuid; c uuid;
  bont uuid; miller uuid; ath3 uuid;
  winner uuid; norm uuid;
  opt_home uuid; opt_away uuid; opt_bont uuid; opt_other uuid; ng_home uuid; ng uuid;
  s jsonb; q integer; n integer; ts timestamptz;
  bal_a integer; bal_b integer; profit_a bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM public.markets WHERE status IN ('draft','open','locked'))
    OR EXISTS (SELECT 1 FROM public.quarter_results) OR EXISTS (SELECT 1 FROM public.score_events WHERE voided_at IS NULL) THEN
    RAISE EXCEPTION 'Use an idle rehearsal branch with no active scores, markets or quarter results';
  END IF;
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');
  UPDATE public.game_state SET period_status = 'pre_match', quarter = 1, betting_paused = false,
    home_goals = 0, home_behinds = 0, home_points = 0, away_goals = 0, away_behinds = 0, away_points = 0 WHERE id = 1;

  INSERT INTO public.athletes(display_name) VALUES('Futures Bont ' || suffix) RETURNING id INTO bont;
  INSERT INTO public.athletes(display_name) VALUES('Futures Miller ' || suffix) RETURNING id INTO miller;
  INSERT INTO public.athletes(display_name) VALUES('Futures Third ' || suffix) RETURNING id INTO ath3;

  s := public.kennel_join_player('FA-' || suffix, '', a_hash); a := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('FB-' || suffix, '', b_hash); b := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('FC-' || suffix, '', c_hash); c := (s#>>'{player,id}')::uuid;

  ---------------------------------------------------------------------------
  -- 1. Configuration validation.
  ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.kennel_configure_futures(host_hash, 200, 200, ARRAY[]::uuid[], gen_random_uuid());
    RAISE EXCEPTION 'an empty Norm Smith candidate list was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Name at least one Norm Smith candidate' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.kennel_configure_futures(host_hash, 200, 200, ARRAY[bont, bont], gen_random_uuid());
    RAISE EXCEPTION 'a duplicated candidate was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'A candidate can only be listed once' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM public.kennel_configure_futures(host_hash, 200, 200, ARRAY[gen_random_uuid()], gen_random_uuid());
    RAISE EXCEPTION 'an unknown candidate was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Unknown Norm Smith candidate' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 2. Configure for real, then reconfigure while still draft.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_configure_futures(host_hash, 200, 200, ARRAY[bont, miller], gen_random_uuid());
  SELECT id INTO winner FROM public.markets WHERE type = 'futures_winner';
  SELECT id INTO norm FROM public.markets WHERE type = 'futures_norm_smith';

  IF (SELECT count(*) FROM public.market_options WHERE market_id = norm) <> 3 THEN
    RAISE EXCEPTION 'Norm Smith should carry two candidates plus the catch-all';
  END IF;

  -- Reconfiguring in draft replaces the candidate list cleanly.
  PERFORM public.kennel_configure_futures(host_hash, 200, 200, ARRAY[bont, miller, ath3], gen_random_uuid());
  IF (SELECT count(*) FROM public.market_options WHERE market_id = norm) <> 4 THEN
    RAISE EXCEPTION 'a draft reconfiguration should replace the candidate list';
  END IF;

  -- Shape, per the spec: no quarter, no quarter prize, bounce-locked, capped.
  IF EXISTS (SELECT 1 FROM public.markets WHERE id IN (winner, norm)
    AND (quarter IS NOT NULL OR counts_toward_quarter_prize OR lock_strategy <> 'bounce' OR max_stake <> 200)) THEN
    RAISE EXCEPTION 'a Future has the wrong shape';
  END IF;

  ---------------------------------------------------------------------------
  -- 3. A Future cannot take a stake before it is opened.
  ---------------------------------------------------------------------------
  SELECT id INTO opt_home FROM public.market_options WHERE market_id = winner AND option_key = 'home';
  SELECT id INTO opt_away FROM public.market_options WHERE market_id = winner AND option_key = 'away';
  BEGIN
    PERFORM public.kennel_place_bet(a_hash, winner, opt_home, 50, gen_random_uuid());
    RAISE EXCEPTION 'a draft Future accepted a stake';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Market has locked' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 4. Open both, and confirm they are bounce-locked with no clock.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_open_futures(host_hash, gen_random_uuid());
  IF EXISTS (SELECT 1 FROM public.markets WHERE id IN (winner, norm) AND (status <> 'open' OR locks_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'an opened Future must be open with no locks_at';
  END IF;

  -- Reconfiguration is refused once open: no relabelling under live stakes.
  BEGIN
    PERFORM public.kennel_configure_futures(host_hash, 200, 200, ARRAY[bont], gen_random_uuid());
    RAISE EXCEPTION 'an open Future was reconfigured';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'The match-winner Future is already open and cannot be reconfigured' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 5. Stakes, and the cap applied to the total rather than to each increase.
  ---------------------------------------------------------------------------
  SELECT id INTO opt_bont FROM public.market_options WHERE market_id = norm AND athlete_id = bont;
  SELECT id INTO opt_other FROM public.market_options WHERE market_id = norm AND option_key = 'any_other_player';

  PERFORM public.kennel_place_bet(a_hash, winner, opt_home, 150, gen_random_uuid());
  PERFORM public.kennel_place_bet(b_hash, winner, opt_away, 200, gen_random_uuid());
  PERFORM public.kennel_place_bet(c_hash, winner, opt_away, 100, gen_random_uuid());

  BEGIN
    -- 150 already staked; another 100 would exceed the 200 cap for the market.
    PERFORM public.kennel_place_bet(a_hash, winner, opt_home, 100, gen_random_uuid());
    RAISE EXCEPTION 'the Future cap was applied per increase rather than to the total';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Market cap reached' THEN RAISE; END IF;
  END;
  -- The remaining 50 is allowed.
  PERFORM public.kennel_place_bet(a_hash, winner, opt_home, 50, gen_random_uuid());

  PERFORM public.kennel_place_bet(a_hash, norm, opt_bont, 100, gen_random_uuid());
  PERFORM public.kennel_place_bet(b_hash, norm, opt_other, 100, gen_random_uuid());

  ---------------------------------------------------------------------------
  -- 6. Settling before full time is refused.
  ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.kennel_settle_match_future(host_hash, gen_random_uuid());
    RAISE EXCEPTION 'a Future settled before full time';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Seal full time before settling the Futures' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 7. The Q1 bounce locks both Futures, in the same transaction.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_start_quarter(host_hash, 1, gen_random_uuid());
  IF EXISTS (SELECT 1 FROM public.markets WHERE id IN (winner, norm) AND status <> 'locked') THEN
    RAISE EXCEPTION 'the bounce did not lock both Futures';
  END IF;
  BEGIN
    PERFORM public.kennel_place_bet(c_hash, winner, opt_away, 25, gen_random_uuid());
    RAISE EXCEPTION 'a locked Future accepted a post-bounce stake';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Market has locked' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 8. The generic recovery action refuses a Future.
  ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.kennel_market_action(host_hash, 'settle_market', gen_random_uuid(), winner, opt_home, NULL, 90);
    RAISE EXCEPTION 'settle_market accepted a Future';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This market has its own host action' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 9. Play out to full time. Home wins 12-6.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_record_score(host_hash, 'home', 'goal', gen_random_uuid());
  PERFORM public.kennel_record_score(host_hash, 'away', 'goal', gen_random_uuid());
  PERFORM public.kennel_end_quarter(host_hash, gen_random_uuid());
  FOR q IN 2..3 LOOP
    PERFORM public.kennel_start_quarter(host_hash, q, gen_random_uuid());
    PERFORM public.kennel_end_quarter(host_hash, gen_random_uuid());
  END LOOP;
  PERFORM public.kennel_start_quarter(host_hash, 4, gen_random_uuid());
  PERFORM public.kennel_record_score(host_hash, 'home', 'goal', gen_random_uuid());
  PERFORM public.kennel_end_quarter(host_hash, gen_random_uuid());

  IF (SELECT period_status FROM public.game_state WHERE id = 1) <> 'final' THEN
    RAISE EXCEPTION 'the match should be final after Q4';
  END IF;
  IF (SELECT home_points FROM public.game_state WHERE id = 1) <> 12
    OR (SELECT away_points FROM public.game_state WHERE id = 1) <> 6 THEN
    RAISE EXCEPTION 'unexpected final score';
  END IF;

  ---------------------------------------------------------------------------
  -- 10. A level score voids and refunds rather than picking a side.
  --     Proved in a subtransaction, then rolled back so the real result can run.
  ---------------------------------------------------------------------------
  BEGIN
    -- game_state keeps points consistent with goals and behinds, so level the
    -- score the way a real away goal would.
    UPDATE public.game_state SET away_goals = 2, away_points = 12 WHERE id = 1;
    PERFORM public.kennel_settle_match_future(host_hash, gen_random_uuid());
    IF (SELECT status FROM public.markets WHERE id = winner) <> 'void' THEN
      RAISE EXCEPTION 'a level score should void the match-winner Future';
    END IF;
    IF EXISTS (SELECT 1 FROM public.bets WHERE market_id = winner AND (payout <> stake OR profit <> 0)) THEN
      RAISE EXCEPTION 'a void should refund every stake at zero profit';
    END IF;
    RAISE EXCEPTION 'ROLLBACK_LEVEL_SCORE_SCENARIO';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_LEVEL_SCORE_SCENARIO' THEN RAISE; END IF;
  END;
  IF (SELECT settled_at FROM public.markets WHERE id = winner) IS NOT NULL THEN
    RAISE EXCEPTION 'the level-score subtransaction did not roll back';
  END IF;

  ---------------------------------------------------------------------------
  -- 11. The real settlement. The server derives the winner from its own score.
  ---------------------------------------------------------------------------
  SELECT balance INTO bal_a FROM public.players WHERE id = a;
  PERFORM public.kennel_settle_match_future(host_hash, gen_random_uuid());

  IF (SELECT status FROM public.markets WHERE id = winner) <> 'settled'
    OR (SELECT winning_option_id FROM public.markets WHERE id = winner) <> opt_home THEN
    RAISE EXCEPTION 'home should have won the match-winner Future';
  END IF;

  -- Winning pool 200 (A), losing pool 300 (B 200 + C 100).
  -- A: payout = 200 + floor(200 * 300 / 200) = 500, profit 300.
  IF (SELECT payout FROM public.bets WHERE market_id = winner AND player_id = a) <> 500
    OR (SELECT profit FROM public.bets WHERE market_id = winner AND player_id = a) <> 300 THEN
    RAISE EXCEPTION 'match-winner payout arithmetic';
  END IF;
  IF (SELECT balance FROM public.players WHERE id = a) <> bal_a + 500 THEN
    RAISE EXCEPTION 'the payout did not reach the balance';
  END IF;
  IF EXISTS (SELECT 1 FROM public.bets WHERE market_id = winner AND player_id IN (b, c) AND (payout <> 0 OR profit <> -stake)) THEN
    RAISE EXCEPTION 'losing backers should lose exactly their stake';
  END IF;
  -- Never distribute more than the losing pool.
  IF (SELECT settlement_losing_pool_bones - settlement_dust_bones FROM public.markets WHERE id = winner) <> 300 THEN
    RAISE EXCEPTION 'payout plus dust must conserve the losing pool';
  END IF;

  ---------------------------------------------------------------------------
  -- 12. Settling twice must not pay twice.
  ---------------------------------------------------------------------------
  SELECT balance INTO bal_a FROM public.players WHERE id = a;
  ts := (SELECT settled_at FROM public.markets WHERE id = winner);
  PERFORM public.kennel_settle_match_future(host_hash, gen_random_uuid());
  IF (SELECT balance FROM public.players WHERE id = a) <> bal_a THEN
    RAISE EXCEPTION 'settling twice paid twice';
  END IF;
  IF (SELECT settled_at FROM public.markets WHERE id = winner) <> ts THEN
    RAISE EXCEPTION 'settling twice rewrote the settlement';
  END IF;

  ---------------------------------------------------------------------------
  -- 13. Norm Smith: an option from another market can never settle it.
  ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.kennel_settle_norm_smith(host_hash, opt_home, gen_random_uuid());
    RAISE EXCEPTION 'a foreign option settled Norm Smith';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Choose a candidate from this market' THEN RAISE; END IF;
  END;

  -- The catch-all wins, which is the case a candidate-only market would have voided.
  SELECT balance INTO bal_b FROM public.players WHERE id = b;
  PERFORM public.kennel_settle_norm_smith(host_hash, opt_other, gen_random_uuid());
  IF (SELECT status FROM public.markets WHERE id = norm) <> 'settled' THEN
    RAISE EXCEPTION 'Norm Smith should have settled on Any other player';
  END IF;
  -- Winning pool 100 (B), losing pool 100 (A). B: 100 + floor(100*100/100) = 200.
  IF (SELECT payout FROM public.bets WHERE market_id = norm AND player_id = b) <> 200 THEN
    RAISE EXCEPTION 'Norm Smith payout arithmetic';
  END IF;
  IF (SELECT balance FROM public.players WHERE id = b) <> bal_b + 200 THEN
    RAISE EXCEPTION 'the Norm Smith payout did not reach the balance';
  END IF;

  ---------------------------------------------------------------------------
  -- 14. Futures decide Top Dog, never a quarter prize.
  ---------------------------------------------------------------------------
  FOR q IN 1..4 LOOP
    IF EXISTS (
      SELECT 1 FROM jsonb_array_elements(public.kennel_ladder(q, NULL, 100)) AS row
      WHERE (row->>'playerId')::uuid = a AND (row->>'profit')::bigint <> 0
    ) THEN
      RAISE EXCEPTION 'a Future leaked into the quarter % ladder', q;
    END IF;
  END LOOP;

  SELECT (row->>'profit')::bigint INTO profit_a
    FROM jsonb_array_elements(public.kennel_ladder(NULL, NULL, 100)) AS row
    WHERE (row->>'playerId')::uuid = a;
  -- A missing row would make the comparison NULL, which IF treats as false and
  -- would pass this test vacuously. Demand the row before comparing it.
  IF profit_a IS NULL THEN
    RAISE EXCEPTION 'the overall ladder is missing a player who staked on both Futures';
  END IF;
  -- +300 on the match winner, -100 on Norm Smith.
  IF profit_a <> 200 THEN
    RAISE EXCEPTION 'Top Dog should include Futures profit, got %', profit_a;
  END IF;

  ---------------------------------------------------------------------------
  -- 15. Invariants.
  ---------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM public.players p WHERE p.balance <> (SELECT COALESCE(sum(amount),0) FROM public.ledger WHERE player_id = p.id)) THEN
    RAISE EXCEPTION 'ledger balance reconciliation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.market_options o WHERE o.pool_bones <> (SELECT COALESCE(sum(stake),0) FROM public.bets WHERE market_id = o.market_id AND option_id = o.id)) THEN
    RAISE EXCEPTION 'pool reconciliation';
  END IF;

  RAISE EXCEPTION 'PHASE_THREE_FUTURES_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
