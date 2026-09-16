-- Phase 3, step 1 assertions: bounce locking and the live-play market invariant.
--
-- Run by scripts/verify-phase-three.mjs, which prepends the unapplied migration
-- so the whole thing rolls back. Nothing here is allowed to persist.
--
-- What must hold:
--   No market other than Next Goal is ever `open` while period_status = 'live'.
DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  a_hash text := repeat('a', 32) || suffix;
  b_hash text := repeat('b', 32) || suffix;
  a uuid; b uuid;
  ng uuid; studs1 uuid; studs2 uuid; futures uuid;
  opt_a uuid; opt_b uuid; ng_home uuid;
  ath1 uuid; ath2 uuid; ath3 uuid; ath4 uuid;
  s jsonb; locked_count integer; strategy text;
BEGIN
  -- Same idle-branch guard as the Phase 2 suite: never run over live rehearsal state.
  IF EXISTS (SELECT 1 FROM public.markets WHERE status IN ('draft','open','locked'))
    OR EXISTS (SELECT 1 FROM public.quarter_results) OR EXISTS (SELECT 1 FROM public.score_events WHERE voided_at IS NULL) THEN
    RAISE EXCEPTION 'Use an idle rehearsal branch with no active scores, markets or quarter results';
  END IF;
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');
  UPDATE public.game_state SET period_status = 'pre_match', quarter = 1, betting_paused = false,
    home_goals = 0, home_behinds = 0, home_points = 0, away_goals = 0, away_behinds = 0, away_points = 0 WHERE id = 1;

  s := public.kennel_join_player('T3A-' || suffix, '', a_hash); a := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('T3B-' || suffix, '', b_hash); b := (s#>>'{player,id}')::uuid;

  -- Studs options name athletes, per the step 2 option-key rule.
  INSERT INTO public.athletes(display_name) VALUES('Lock Athlete One ' || suffix) RETURNING id INTO ath1;
  INSERT INTO public.athletes(display_name) VALUES('Lock Athlete Two ' || suffix) RETURNING id INTO ath2;
  INSERT INTO public.athletes(display_name) VALUES('Lock Athlete Three ' || suffix) RETURNING id INTO ath3;
  INSERT INTO public.athletes(display_name) VALUES('Lock Athlete Four ' || suffix) RETURNING id INTO ath4;

  ---------------------------------------------------------------------------
  -- 1. lock_strategy defaults, and is pinned to the market type.
  ---------------------------------------------------------------------------
  INSERT INTO public.markets(type, quarter, title, status)
    VALUES('next_goal', 1, 'default check', 'draft') RETURNING id, lock_strategy INTO ng, strategy;
  IF strategy <> 'deadline' THEN RAISE EXCEPTION 'next_goal should default to deadline'; END IF;
  DELETE FROM public.markets WHERE id = ng;

  BEGIN
    INSERT INTO public.markets(type, quarter, title, status, lock_strategy)
      VALUES('next_goal', 1, 'bad', 'draft', 'bounce');
    RAISE EXCEPTION 'bounce next_goal accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%markets_lock_strategy_matches_type%' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO public.markets(type, quarter, title, status, lock_strategy)
      VALUES('studs_v_spuds', 1, 'bad', 'draft', 'deadline');
    RAISE EXCEPTION 'deadline studs accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%markets_lock_strategy_matches_type%' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 2. The open window: a deadline market needs a clock, a bounce market must not have one.
  ---------------------------------------------------------------------------
  BEGIN
    INSERT INTO public.markets(type, quarter, title, status, lock_strategy, opens_at, locks_at)
      VALUES('studs_v_spuds', 1, 'bad', 'open', 'bounce', clock_timestamp(), clock_timestamp() + interval '1 hour');
    RAISE EXCEPTION 'bounce market with a deadline accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%markets_open_window%' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO public.markets(type, quarter, title, status, lock_strategy, opens_at, locks_at)
      VALUES('next_goal', 1, 'bad', 'open', 'deadline', clock_timestamp(), NULL);
    RAISE EXCEPTION 'deadline market without a clock accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%markets_open_window%' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 3. A bounce market opens fine in the break, and takes a stake there.
  ---------------------------------------------------------------------------
  INSERT INTO public.markets(type, quarter, title, status, lock_strategy, opens_at, counts_toward_quarter_prize)
    VALUES('studs_v_spuds', 1, 'Studs Q1 slot 1', 'open', 'bounce', clock_timestamp(), true) RETURNING id INTO studs1;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
    VALUES(studs1, 'athlete_a', 'Athlete One', 0, ath1), (studs1, 'athlete_b', 'Athlete Two', 1, ath2);
  SELECT id INTO opt_a FROM public.market_options WHERE market_id = studs1 AND option_key = 'athlete_a';
  SELECT id INTO opt_b FROM public.market_options WHERE market_id = studs1 AND option_key = 'athlete_b';

  PERFORM public.kennel_place_bet(a_hash, studs1, opt_a, 100, gen_random_uuid());
  IF (SELECT pool_bones FROM public.market_options WHERE id = opt_a) <> 100 THEN
    RAISE EXCEPTION 'break-time stake on a bounce market';
  END IF;

  ---------------------------------------------------------------------------
  -- 4. Play cannot resume while a bounce market is still open (guard from the game side).
  ---------------------------------------------------------------------------
  BEGIN
    UPDATE public.game_state SET period_status = 'live' WHERE id = 1;
    RAISE EXCEPTION 'live transition with an open bounce market accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Lock every bounce-locked market before play resumes' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 5. start_quarter locks every open bounce market in the same transaction.
  ---------------------------------------------------------------------------
  INSERT INTO public.markets(type, quarter, title, status, lock_strategy, opens_at)
    VALUES('studs_v_spuds', 1, 'Studs Q1 slot 2', 'open', 'bounce', clock_timestamp()) RETURNING id INTO studs2;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
    VALUES(studs2, 'athlete_a', 'Athlete Three', 0, ath3), (studs2, 'athlete_b', 'Athlete Four', 1, ath4);
  INSERT INTO public.markets(type, title, status, lock_strategy, opens_at, max_stake, counts_toward_quarter_prize)
    VALUES('futures_winner', 'Match winner', 'open', 'bounce', clock_timestamp(), 200, false) RETURNING id INTO futures;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(futures, 'home', 'Home', 0), (futures, 'away', 'Away', 1);

  IF (SELECT count(*) FROM public.markets WHERE status = 'open' AND lock_strategy = 'bounce') <> 3 THEN
    RAISE EXCEPTION 'expected three open bounce markets before the bounce';
  END IF;

  s := public.kennel_start_quarter(host_hash, 1, gen_random_uuid());

  SELECT count(*) INTO locked_count FROM public.markets
    WHERE id IN (studs1, studs2, futures) AND status = 'locked';
  IF locked_count <> 3 THEN RAISE EXCEPTION 'the opening bounce must lock every bounce market'; END IF;
  IF EXISTS (SELECT 1 FROM public.markets WHERE status = 'open' AND lock_strategy = 'bounce') THEN
    RAISE EXCEPTION 'a bounce market survived the opening bounce';
  END IF;
  IF (SELECT period_status FROM public.game_state WHERE id = 1) <> 'live' THEN
    RAISE EXCEPTION 'start_quarter should leave the game live';
  END IF;

  -- Next Goal is the one market the bounce opens, not closes.
  SELECT id INTO ng FROM public.markets WHERE type = 'next_goal' AND status = 'open';
  IF ng IS NULL THEN RAISE EXCEPTION 'the bounce should open Next Goal'; END IF;

  ---------------------------------------------------------------------------
  -- 6. During live play a bounce market cannot be opened at all.
  ---------------------------------------------------------------------------
  BEGIN
    UPDATE public.markets SET status = 'open' WHERE id = studs1;
    RAISE EXCEPTION 'reopening a bounce market during live play accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'A bounce-locked market cannot be open during live play' THEN RAISE; END IF;
  END;

  BEGIN
    INSERT INTO public.markets(type, quarter, title, status, lock_strategy, opens_at)
      VALUES('studs_v_spuds', 1, 'Studs mid-play', 'open', 'bounce', clock_timestamp());
    RAISE EXCEPTION 'opening a new bounce market during live play accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'A bounce-locked market cannot be open during live play' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 7. Belt and braces: even a stale `open` bounce row takes no stake while live.
  --    The trigger is what stops this row existing; place_bet must refuse it anyway.
  ---------------------------------------------------------------------------
  ALTER TABLE public.markets DISABLE TRIGGER markets_bounce_lock_guard;
  UPDATE public.markets SET status = 'open' WHERE id = studs1;
  ALTER TABLE public.markets ENABLE TRIGGER markets_bounce_lock_guard;
  BEGIN
    PERFORM public.kennel_place_bet(b_hash, studs1, opt_a, 25, gen_random_uuid());
    RAISE EXCEPTION 'stale open bounce market accepted a stake during live play';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Market has locked' THEN RAISE; END IF;
  END;
  ALTER TABLE public.markets DISABLE TRIGGER markets_bounce_lock_guard;
  UPDATE public.markets SET status = 'locked' WHERE id = studs1;
  ALTER TABLE public.markets ENABLE TRIGGER markets_bounce_lock_guard;

  ---------------------------------------------------------------------------
  -- 8. Regression: Next Goal is unaffected and still takes stakes in play.
  ---------------------------------------------------------------------------
  SELECT id INTO ng_home FROM public.market_options WHERE market_id = ng AND option_key = 'home';
  PERFORM public.kennel_place_bet(a_hash, ng, ng_home, 50, gen_random_uuid());
  IF (SELECT pool_bones FROM public.market_options WHERE id = ng_home) <> 50 THEN
    RAISE EXCEPTION 'Next Goal must still accept stakes during live play';
  END IF;
  IF (SELECT lock_strategy FROM public.markets WHERE id = ng) <> 'deadline' THEN
    RAISE EXCEPTION 'Next Goal must stay deadline-locked';
  END IF;

  ---------------------------------------------------------------------------
  -- 9. The invariant itself, stated once over the whole table.
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

  RAISE EXCEPTION 'PHASE_THREE_LOCK_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
