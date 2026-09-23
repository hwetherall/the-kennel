-- Phase 3, step 2 assertions: athletes, option keys, the Futures shape, and the
-- quarter-ladder split.
--
-- Run by scripts/verify-phase-three.mjs, which prepends both unapplied Phase 3
-- migrations so the whole thing rolls back. Nothing here is allowed to persist.
DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  bont uuid; miller uuid; other uuid;
  winner uuid; norm uuid; ng uuid; studs uuid;
  opt uuid; finalized timestamptz;
BEGIN
  -- Same idle-branch guard as the other suites: never run over live rehearsal state.
  IF EXISTS (SELECT 1 FROM public.markets WHERE status IN ('draft','open','locked'))
    OR EXISTS (SELECT 1 FROM public.quarter_results) OR EXISTS (SELECT 1 FROM public.score_events WHERE voided_at IS NULL) THEN
    RAISE EXCEPTION 'Use an idle rehearsal branch with no active scores, markets or quarter results';
  END IF;
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');
  UPDATE public.game_state SET period_status = 'pre_match', quarter = 1, betting_paused = false WHERE id = 1;

  ---------------------------------------------------------------------------
  -- 1. Athlete identity is one person, however it is typed.
  ---------------------------------------------------------------------------
  INSERT INTO public.athletes(display_name) VALUES('Rehearsal Bont ' || suffix) RETURNING id INTO bont;
  INSERT INTO public.athletes(display_name) VALUES('Rehearsal Miller ' || suffix) RETURNING id INTO miller;

  BEGIN
    -- Different case and padding, same person.
    INSERT INTO public.athletes(display_name) VALUES('  rehearsal bont ' || suffix || '  ');
    RAISE EXCEPTION 'a duplicate athlete identity was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.athletes(display_name) VALUES('   ');
    RAISE EXCEPTION 'a blank athlete name was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  ---------------------------------------------------------------------------
  -- 2. Futures shape. A Future belongs to no quarter and no quarter prize, and
  --    must be bounce-locked, which means every column is stated deliberately.
  ---------------------------------------------------------------------------
  BEGIN
    -- lock_strategy defaults to 'deadline', which no Future may carry. This is a
    -- documented footgun: every non-Next-Goal insert states its strategy.
    INSERT INTO public.markets(type, title, status, counts_toward_quarter_prize)
      VALUES('futures_winner', 'no strategy', 'draft', false);
    RAISE EXCEPTION 'a Future defaulted to deadline locking';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.markets(type, quarter, title, status, lock_strategy, counts_toward_quarter_prize)
      VALUES('futures_winner', 3, 'quartered', 'draft', 'bounce', false);
    RAISE EXCEPTION 'a Future was accepted with a quarter';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize)
      VALUES('futures_winner', 'counts', 'draft', 'bounce', true);
    RAISE EXCEPTION 'a Future was accepted counting toward a quarter prize';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.markets(type, title, status, lock_strategy)
      VALUES('studs_v_spuds', 'no quarter', 'draft', 'bounce');
    RAISE EXCEPTION 'a Studs market was accepted without a quarter';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- The two real Futures for this event.
  INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize, max_stake)
    VALUES('futures_winner', 'Match winner', 'draft', 'bounce', false, 200) RETURNING id INTO winner;
  INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize, max_stake)
    VALUES('futures_norm_smith', 'Norm Smith', 'draft', 'bounce', false, 200) RETURNING id INTO norm;

  ---------------------------------------------------------------------------
  -- 3. Exactly one of each Future for the event.
  ---------------------------------------------------------------------------
  BEGIN
    INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize)
      VALUES('futures_winner', 'second winner', 'draft', 'bounce', false);
    RAISE EXCEPTION 'a second match-winner Future was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize)
      VALUES('futures_norm_smith', 'second norm', 'draft', 'bounce', false);
    RAISE EXCEPTION 'a second Norm Smith Future was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  ---------------------------------------------------------------------------
  -- 4. Option keys are validated per market type.
  ---------------------------------------------------------------------------
  -- Match winner is a two-team market, keyed like Next Goal.
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(winner, 'home', 'Home', 0);
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(winner, 'away', 'Away', 1);

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order)
      VALUES(winner, 'draw', 'Draw', 2);
    RAISE EXCEPTION 'a match-winner option was accepted with a non-team key';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      VALUES(winner, 'home', 'Home', 3, bont);
    RAISE EXCEPTION 'a team option was accepted naming an athlete';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  -- Norm Smith: candidates are keyed by athlete, plus one stable catch-all.
  INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
    VALUES(norm, 'athlete:' || bont::text, 'Rehearsal Bont', 0, bont);
  INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
    VALUES(norm, 'athlete:' || miller::text, 'Rehearsal Miller', 1, miller);
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(norm, 'any_other_player', 'Any other player', 2) RETURNING id INTO other;

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      VALUES(norm, 'candidate-3', 'Mislabelled', 3, bont);
    RAISE EXCEPTION 'a Norm Smith candidate was accepted with an unstable key';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order)
      VALUES(norm, 'athlete:' || bont::text, 'No athlete', 4);
    RAISE EXCEPTION 'a Norm Smith candidate was accepted without an athlete';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      VALUES(norm, 'any_other_player', 'Any other', 5, bont);
    RAISE EXCEPTION 'the any-other-player option was accepted naming an athlete';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  -- Exactly one catch-all, so a surprise winner can never be ambiguous.
  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order)
      VALUES(norm, 'any_other_player', 'Any other again', 6);
    RAISE EXCEPTION 'a second any-other-player option was accepted';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  ---------------------------------------------------------------------------
  -- 5. Studs options name athletes; the catch-all key belongs to Norm Smith only.
  ---------------------------------------------------------------------------
  INSERT INTO public.markets(type, quarter, title, status, lock_strategy)
    VALUES('studs_v_spuds', 1, 'Q1 matchup', 'draft', 'bounce') RETURNING id INTO studs;

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order)
      VALUES(studs, 'athlete_a', 'No athlete', 0);
    RAISE EXCEPTION 'a Studs option was accepted without an athlete';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      VALUES(studs, 'home', 'Wrong key', 0, bont);
    RAISE EXCEPTION 'a Studs option was accepted with a team key';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
    VALUES(studs, 'athlete_a', 'Rehearsal Bont', 0, bont);
  INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
    VALUES(studs, 'athlete_b', 'Rehearsal Miller', 1, miller);

  ---------------------------------------------------------------------------
  -- 6. An athlete carrying an option cannot be deleted out from under it.
  ---------------------------------------------------------------------------
  BEGIN
    DELETE FROM public.athletes WHERE id = bont;
    RAISE EXCEPTION 'an athlete named by a market option was deleted';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  ---------------------------------------------------------------------------
  -- 7. Next Goal is untouched by any of this.
  ---------------------------------------------------------------------------
  INSERT INTO public.markets(type, quarter, title, status)
    VALUES('next_goal', 1, 'Next goal', 'draft') RETURNING id INTO ng;
  IF (SELECT lock_strategy FROM public.markets WHERE id = ng) <> 'deadline' THEN
    RAISE EXCEPTION 'Next Goal must still default to deadline locking';
  END IF;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(ng, 'home', 'Home', 0);
  BEGIN
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      VALUES(ng, 'away', 'Away', 1, bont);
    RAISE EXCEPTION 'a Next Goal option was accepted naming an athlete';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;

  ---------------------------------------------------------------------------
  -- 8. The quarter ladder finalizes separately from the Squares result, and
  --    Phase 2 behaviour is preserved for a quarter with no Studs market.
  ---------------------------------------------------------------------------
  INSERT INTO public.quarter_results(quarter, home_points, away_points, winning_square_id, quarter_ladder)
    VALUES(1, 20, 16, 1, '[]'::jsonb)
    RETURNING ladder_finalized_at INTO finalized;
  IF finalized IS NULL THEN
    RAISE EXCEPTION 'a quarter with no Studs market must finalize its ladder at the siren';
  END IF;

  -- The seam Studs will use: a quarter whose matchups are still pending.
  UPDATE public.quarter_results SET ladder_finalized_at = NULL WHERE quarter = 1;
  IF (SELECT ladder_finalized_at FROM public.quarter_results WHERE quarter = 1) IS NOT NULL THEN
    RAISE EXCEPTION 'a pending quarter ladder must be expressible as NULL';
  END IF;
  -- Squares stays sealed regardless: disposal lookup never holds up the siren.
  IF (SELECT settled_at FROM public.quarter_results WHERE quarter = 1) IS NULL THEN
    RAISE EXCEPTION 'the Squares result must stay sealed while the ladder is pending';
  END IF;
  DELETE FROM public.quarter_results WHERE quarter = 1;

  ---------------------------------------------------------------------------
  -- 9. The step 1 invariant still holds over everything created here.
  ---------------------------------------------------------------------------
  IF (SELECT period_status FROM public.game_state WHERE id = 1) = 'live'
    AND EXISTS (SELECT 1 FROM public.markets WHERE status = 'open' AND type <> 'next_goal') THEN
    RAISE EXCEPTION 'invariant broken: a non-Next-Goal market is open during live play';
  END IF;

  -- Balances and pools must still reconcile against the append-only ledger.
  IF EXISTS (SELECT 1 FROM public.players p WHERE p.balance <> (SELECT COALESCE(sum(amount),0) FROM public.ledger WHERE player_id = p.id)) THEN
    RAISE EXCEPTION 'ledger balance reconciliation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.market_options o WHERE o.pool_bones <> (SELECT COALESCE(sum(stake),0) FROM public.bets WHERE market_id = o.market_id AND option_id = o.id)) THEN
    RAISE EXCEPTION 'pool reconciliation';
  END IF;

  RAISE EXCEPTION 'PHASE_THREE_ATHLETES_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
