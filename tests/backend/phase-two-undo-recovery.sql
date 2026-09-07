-- Approved rule: undo reverses later settlements and voids/refunds their markets.
-- All setup and mutations roll back, on failure as well as success.
DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  a_hash text := repeat('a', 32) || suffix;
  b_hash text := repeat('b', 32) || suffix;
  a uuid; b uuid; original_market uuid; successor uuid; recovery uuid; home uuid; away uuid;
  s jsonb; receipt jsonb; previous_market jsonb; undo_key uuid; ledger_count bigint;
  scenario integer;
BEGIN
  IF EXISTS (SELECT 1 FROM public.markets WHERE status IN ('draft','open','locked'))
    OR EXISTS (SELECT 1 FROM public.quarter_results)
    OR EXISTS (SELECT 1 FROM public.score_events WHERE voided_at IS NULL) THEN
    RAISE EXCEPTION 'Use an idle rehearsal branch with no active scores, markets or quarter results';
  END IF;
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');
  UPDATE public.game_state SET period_status = 'pre_match', quarter = 1, betting_paused = false,
    home_goals = 0, home_behinds = 0, home_points = 0, away_goals = 0, away_behinds = 0, away_points = 0 WHERE id = 1;
  s := public.kennel_join_player('UndoA-' || suffix, '', a_hash); a := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('UndoB-' || suffix, '', b_hash); b := (s#>>'{player,id}')::uuid;
  FOR scenario IN 1..5 LOOP
  BEGIN
  s := public.kennel_start_quarter(host_hash, 1, gen_random_uuid());
  original_market := (s#>>'{activeMarket,id}')::uuid;
  SELECT id INTO home FROM public.market_options WHERE market_id = original_market AND option_key = 'home';
  SELECT id INTO away FROM public.market_options WHERE market_id = original_market AND option_key = 'away';
  PERFORM public.kennel_place_bet(a_hash, original_market, home, 1000, gen_random_uuid());
  PERFORM public.kennel_place_bet(b_hash, original_market, CASE WHEN scenario = 4 THEN home ELSE away END, 500, gen_random_uuid());
  IF scenario = 5 THEN
    PERFORM public.kennel_market_action(host_hash, 'void_market', gen_random_uuid(), original_market, NULL, 'Recovery before goal');
  END IF;
  previous_market := public.kennel_market_snapshot(original_market);
  s := public.kennel_record_score(host_hash, CASE WHEN scenario = 4 THEN 'away' ELSE 'home' END, 'goal', gen_random_uuid());
  successor := (s#>>'{activeMarket,id}')::uuid;
  IF (SELECT balance FROM public.players WHERE id = a) <> (CASE WHEN scenario IN (4,5) THEN 1000 ELSE 1500 END) THEN RAISE EXCEPTION 'setup payout'; END IF;
  SELECT id INTO home FROM public.market_options WHERE market_id = successor AND option_key = 'home';
  SELECT id INTO away FROM public.market_options WHERE market_id = successor AND option_key = 'away';
  PERFORM public.kennel_place_bet(a_hash, successor, home, (SELECT balance FROM public.players WHERE id = a), gen_random_uuid());
  PERFORM public.kennel_place_bet(b_hash, successor, away, (SELECT balance FROM public.players WHERE id = b), gen_random_uuid());
  IF scenario = 3 THEN
    s := public.kennel_record_score(host_hash, 'away', 'goal', gen_random_uuid());
  ELSE
    PERFORM public.kennel_market_action(host_hash, 'settle_market', gen_random_uuid(), successor, away);
  END IF;
  IF (SELECT balance FROM public.players WHERE id = a) <> 0 THEN RAISE EXCEPTION 'setup later loss'; END IF;
  IF scenario IN (2,3) THEN
    -- Spend settlement credits through a manually voided market, a manually
    -- settled one-sided market, and a final unresolved market.
    IF scenario = 2 THEN s := public.kennel_market_action(host_hash, 'open_next_goal', gen_random_uuid()); END IF;
    recovery := (s#>>'{activeMarket,id}')::uuid;
    SELECT id INTO home FROM public.market_options WHERE market_id = recovery AND option_key = 'home';
    PERFORM public.kennel_place_bet(b_hash, recovery, home, 2000, gen_random_uuid());
    PERFORM public.kennel_market_action(host_hash, 'void_market', gen_random_uuid(), recovery, NULL, 'Recovery void');
    s := public.kennel_market_action(host_hash, 'open_next_goal', gen_random_uuid());
    recovery := (s#>>'{activeMarket,id}')::uuid;
    SELECT id INTO home FROM public.market_options WHERE market_id = recovery AND option_key = 'home';
    PERFORM public.kennel_place_bet(b_hash, recovery, home, 2000, gen_random_uuid());
    PERFORM public.kennel_market_action(host_hash, 'settle_market', gen_random_uuid(), recovery, home);
    s := public.kennel_market_action(host_hash, 'open_next_goal', gen_random_uuid());
    recovery := (s#>>'{activeMarket,id}')::uuid;
    SELECT id INTO home FROM public.market_options WHERE market_id = recovery AND option_key = 'home';
    PERFORM public.kennel_place_bet(b_hash, recovery, home, 2000, gen_random_uuid());
  END IF;
  IF scenario = 3 THEN
    -- Undo the second goal first, then the first. Historical void refunds must
    -- remain intact and the earlier market must become the sole active market.
    s := public.kennel_undo_latest_score(host_hash, gen_random_uuid());
    IF (s#>>'{activeMarket,id}')::uuid IS DISTINCT FROM successor THEN RAISE EXCEPTION 'second-goal restore'; END IF;
    IF public.kennel_market_snapshot(original_market)->>'status' <> 'settled' THEN RAISE EXCEPTION 'earlier result changed too soon'; END IF;
  END IF;
  -- The product contract says the latest score must remain undoable.
  undo_key := gen_random_uuid();
  s := public.kennel_undo_latest_score(host_hash, undo_key);
  IF (s#>>'{game,homePoints}')::integer <> 0 OR (s#>>'{game,awayPoints}')::integer <> 0 THEN RAISE EXCEPTION 'score not undone'; END IF;
  IF scenario = 5 THEN
    IF s->'activeMarket' IS DISTINCT FROM 'null'::jsonb OR public.kennel_market_snapshot(original_market) IS DISTINCT FROM previous_market THEN
      RAISE EXCEPTION 'missing prior market must preserve earlier void';
    END IF;
  ELSE
    IF (s#>>'{activeMarket,id}')::uuid IS DISTINCT FROM original_market
      OR s#>>'{activeMarket,status}' NOT IN ('open','locked') THEN RAISE EXCEPTION 'original market not restored'; END IF;
  END IF;
  IF (SELECT balance FROM public.players WHERE id = a) <> (CASE WHEN scenario = 5 THEN 1000 ELSE 0 END)
    OR (SELECT balance FROM public.players WHERE id = b) <> (CASE WHEN scenario = 5 THEN 1000 ELSE 500 END) THEN RAISE EXCEPTION 'balances not restored'; END IF;
  IF EXISTS (SELECT 1 FROM public.markets WHERE sequence > (SELECT sequence FROM public.markets WHERE id = original_market) AND status <> 'void') THEN
    RAISE EXCEPTION 'later market not voided';
  END IF;
  IF EXISTS (SELECT 1 FROM public.bets WHERE market_id <> original_market AND player_id IN (a,b) AND (profit IS DISTINCT FROM 0 OR payout IS DISTINCT FROM stake)) THEN
    RAISE EXCEPTION 'later bets not refunded';
  END IF;
  IF EXISTS (SELECT 1 FROM public.market_options o WHERE o.pool_bones <> (SELECT COALESCE(sum(stake),0) FROM public.bets WHERE market_id = o.market_id AND option_id = o.id)) THEN
    RAISE EXCEPTION 'pool reconciliation';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.kennel_ladder(1)) WHERE (value->>'profit')::integer <> 0) THEN RAISE EXCEPTION 'ladder still includes reversed profit'; END IF;
  SELECT count(*) INTO ledger_count FROM public.ledger;
  receipt := public.kennel_undo_latest_score(host_hash, undo_key);
  IF receipt IS DISTINCT FROM s OR (SELECT count(*) FROM public.ledger) <> ledger_count THEN RAISE EXCEPTION 'undo retry changed history'; END IF;
  IF EXISTS (SELECT 1 FROM public.players p WHERE p.balance <>
    (SELECT COALESCE(sum(amount),0) FROM public.ledger WHERE player_id = p.id)) THEN
    RAISE EXCEPTION 'ledger reconciliation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.ledger r JOIN public.ledger l ON l.id = r.reversal_of_id WHERE r.amount <> -l.amount OR r.kind <> l.kind OR r.player_id <> l.player_id) THEN
    RAISE EXCEPTION 'reversal reconciliation';
  END IF;
  -- Reset this scenario using a subtransaction, retaining the original guests.
  RAISE EXCEPTION USING ERRCODE = 'P2001', MESSAGE = 'SCENARIO_PASSED';
  EXCEPTION WHEN SQLSTATE 'P2001' THEN NULL;
  END;
  END LOOP;
  RAISE EXCEPTION 'PHASE_TWO_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
