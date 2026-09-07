DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  a_hash text := repeat('a', 32) || suffix;
  b_hash text := repeat('b', 32) || suffix;
  c_hash text := repeat('c', 32) || suffix;
  a uuid; b uuid; c uuid; purchase uuid; batch uuid; m uuid; successor uuid; home uuid; away uuid;
  key uuid; score_key uuid; undo_key uuid; initial_home integer; ledger_count bigint;
  s jsonb; before_state jsonb; receipt jsonb; failure text; frozen jsonb;
BEGIN
  -- Keep this rehearsal independent of prior branch activity, without deleting it.
  IF EXISTS (SELECT 1 FROM public.markets WHERE status IN ('draft','open','locked'))
    OR EXISTS (SELECT 1 FROM public.quarter_results) OR EXISTS (SELECT 1 FROM public.score_events WHERE voided_at IS NULL) THEN
    RAISE EXCEPTION 'Use an idle rehearsal branch with no active scores, markets or quarter results';
  END IF;
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');
  UPDATE public.game_state SET period_status = 'pre_match', quarter = 1, betting_paused = false,
    home_goals = 0, home_behinds = 0, home_points = 0, away_goals = 0, away_behinds = 0, away_points = 0 WHERE id = 1;

  s := public.kennel_join_player('TestA-' || suffix, '', a_hash); a := (s#>>'{player,id}')::uuid;
  IF (s#>>'{player,balance}')::integer <> 1000 THEN RAISE EXCEPTION 'courtesy grant'; END IF;
  s := public.kennel_join_player('TestA-' || suffix, '', a_hash);
  IF (s#>>'{player,balance}')::integer <> 1000 OR (SELECT count(*) FROM public.ledger WHERE player_id = a) <> 1 THEN RAISE EXCEPTION 'join retry'; END IF;
  s := public.kennel_join_player('TestB-' || suffix, '', b_hash); b := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('TestC-' || suffix, '', c_hash); c := (s#>>'{player,id}')::uuid;

  INSERT INTO public.square_import_batches(checksum, source_name) VALUES(suffix, 'Phase 2 test') RETURNING id INTO batch;
  INSERT INTO public.squares_purchases(batch_id, source_ref, purchaser_name, purchaser_email, squares_count)
    VALUES(batch, suffix, 'Test purchase', suffix || '@example.invalid', 2) RETURNING id INTO purchase;
  key := gen_random_uuid();
  PERFORM public.kennel_link_purchase(host_hash, purchase, a, key);
  PERFORM public.kennel_link_purchase(host_hash, purchase, a, key);
  IF (SELECT balance FROM public.players WHERE id = a) <> 1500 THEN RAISE EXCEPTION 'two-square grant retry'; END IF;
  UPDATE public.squares_purchases SET squares_count = 4 WHERE id = purchase;
  PERFORM public.kennel_link_purchase(host_hash, purchase, a, gen_random_uuid());
  IF (SELECT balance FROM public.players WHERE id = a) <> 2000 THEN RAISE EXCEPTION 'incremental square bonus'; END IF;
  UPDATE public.squares_purchases SET squares_count = 6 WHERE id = purchase;
  PERFORM public.kennel_link_purchase(host_hash, purchase, a, gen_random_uuid());
  UPDATE public.squares_purchases SET squares_count = 7 WHERE id = purchase;
  PERFORM public.kennel_link_purchase(host_hash, purchase, a, gen_random_uuid());
  PERFORM public.kennel_link_purchase(host_hash, purchase, NULL, gen_random_uuid());
  PERFORM public.kennel_link_purchase(host_hash, purchase, a, gen_random_uuid());
  IF (SELECT balance FROM public.players WHERE id = a) <> 2250
    OR (SELECT bonus_squares_granted FROM public.players WHERE id = a) <> 5 THEN RAISE EXCEPTION 'capped grant / no clawback'; END IF;

  key := gen_random_uuid(); s := public.kennel_start_quarter(host_hash, 1, key);
  m := (s#>>'{activeMarket,id}')::uuid;
  IF m IS NULL OR (SELECT count(*) FROM public.market_options WHERE market_id = m) <> 2 THEN RAISE EXCEPTION 'market opening'; END IF;
  IF public.kennel_start_quarter(host_hash, 1, key) <> s THEN RAISE EXCEPTION 'start retry'; END IF;
  SELECT id INTO home FROM public.market_options WHERE market_id = m AND option_key = 'home';
  SELECT id INTO away FROM public.market_options WHERE market_id = m AND option_key = 'away';
  key := gen_random_uuid(); receipt := public.kennel_place_bet(a_hash, m, home, 25, key);
  s := public.kennel_place_bet(a_hash, m, home, 25, key);
  IF receipt <> s OR (SELECT stake FROM public.bets WHERE market_id = m AND player_id = a) <> 25 THEN RAISE EXCEPTION 'bet retry'; END IF;
  -- Reusing another guest's key is safe because receipt identity includes the guest.
  PERFORM public.kennel_place_bet(b_hash, m, home, 450, key);
  PERFORM public.kennel_place_bet(a_hash, m, home, 25, gen_random_uuid());
  PERFORM public.kennel_place_bet(c_hash, m, away, 1000, gen_random_uuid());
  IF (SELECT pool_bones FROM public.market_options WHERE id = home) <> 500 THEN RAISE EXCEPTION 'same-side increase'; END IF;

  BEGIN PERFORM public.kennel_place_bet(a_hash, m, away, 25, gen_random_uuid()); RAISE EXCEPTION 'hedge accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Existing selection cannot be changed' THEN RAISE; END IF; END;
  BEGIN PERFORM public.kennel_place_bet(c_hash, m, away, 1, gen_random_uuid()); RAISE EXCEPTION 'overdraw accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Not enough Bones' THEN RAISE; END IF; END;
  BEGIN PERFORM public.kennel_place_bet(a_hash, m, home, 0, gen_random_uuid()); RAISE EXCEPTION 'zero accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Stake must be positive' THEN RAISE; END IF; END;
  BEGIN PERFORM public.kennel_place_bet(a_hash, m, gen_random_uuid(), 25, gen_random_uuid()); RAISE EXCEPTION 'foreign option accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Choose a team from this market' THEN RAISE; END IF; END;
  UPDATE public.markets SET max_stake = 50 WHERE id = m;
  BEGIN PERFORM public.kennel_place_bet(a_hash, m, home, 1, gen_random_uuid()); RAISE EXCEPTION 'cap accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Market cap reached' THEN RAISE; END IF; END;
  UPDATE public.markets SET max_stake = NULL WHERE id = m;
  PERFORM public.kennel_set_pause(host_hash, true, gen_random_uuid());
  BEGIN PERFORM public.kennel_place_bet(a_hash, m, home, 25, gen_random_uuid()); RAISE EXCEPTION 'paused accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Betting is paused' THEN RAISE; END IF; END;
  before_state := public.kennel_market_snapshot(m);
  s := public.kennel_record_score(host_hash, 'away', 'behind', gen_random_uuid());
  IF s->'activeMarket' <> before_state OR (s#>>'{game,awayPoints}')::integer <> 1 THEN RAISE EXCEPTION 'behind or paused scoring'; END IF;
  PERFORM public.kennel_set_pause(host_hash, false, gen_random_uuid());

  UPDATE public.markets SET opens_at = clock_timestamp() - interval '2 minutes', locks_at = clock_timestamp() - interval '1 second' WHERE id = m;
  IF public.kennel_market_snapshot(m)->>'status' <> 'locked' THEN RAISE EXCEPTION 'effective locking'; END IF;
  BEGIN PERFORM public.kennel_place_bet(a_hash, m, home, 25, gen_random_uuid()); RAISE EXCEPTION 'late accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Market has locked' THEN RAISE; END IF; END;

  score_key := gen_random_uuid(); s := public.kennel_record_score(host_hash, 'home', 'goal', score_key);
  successor := (s#>>'{activeMarket,id}')::uuid;
  IF successor = m OR successor IS NULL OR (SELECT count(*) FROM public.markets WHERE status IN ('open','locked','draft')) <> 1 THEN RAISE EXCEPTION 'successor uniqueness'; END IF;
  IF (SELECT payout FROM public.bets WHERE market_id = m AND player_id = a) <> 150
    OR (SELECT profit FROM public.bets WHERE market_id = m AND player_id = a) <> 100
    OR (SELECT balance FROM public.players WHERE id = a) <> 2350 THEN RAISE EXCEPTION 'canonical payout'; END IF;
  IF (SELECT status FROM public.markets WHERE id = m) <> 'settled'
    OR (SELECT settlement_winning_pool_bones FROM public.markets WHERE id = m) <> 500
    OR (SELECT settlement_losing_pool_bones FROM public.markets WHERE id = m) <> 1000
    OR (SELECT settlement_dust_bones FROM public.markets WHERE id = m) <> 0 THEN RAISE EXCEPTION 'settlement audit'; END IF;
  SELECT count(*) INTO ledger_count FROM public.ledger;
  IF public.kennel_record_score(host_hash, 'home', 'goal', score_key) <> s THEN RAISE EXCEPTION 'goal receipt'; END IF;
  PERFORM public.kennel_finish_market(m, home);
  IF (SELECT count(*) FROM public.ledger) <> ledger_count THEN RAISE EXCEPTION 'double credits'; END IF;
  IF (SELECT value->>'profit' FROM jsonb_array_elements(public.kennel_ladder(1)) WHERE value->>'playerId' = a::text) <> '100' THEN RAISE EXCEPTION 'profit ladder'; END IF;

  SELECT id INTO home FROM public.market_options WHERE market_id = successor AND option_key = 'home';
  -- Spend the entire post-payout balance; refund-first undo must still succeed.
  PERFORM public.kennel_place_bet(a_hash, successor, home, 2350, gen_random_uuid());
  undo_key := gen_random_uuid(); s := public.kennel_undo_latest_score(host_hash, undo_key);
  IF (s#>>'{activeMarket,id}')::uuid <> m OR s#>>'{activeMarket,status}' <> 'locked'
    OR (s#>>'{game,homePoints}')::integer <> 0 OR (s#>>'{game,awayPoints}')::integer <> 1 THEN RAISE EXCEPTION 'undo score/market'; END IF;
  IF (SELECT balance FROM public.players WHERE id = a) <> 2200 OR (SELECT balance FROM public.players WHERE id = b) <> 550
    OR (SELECT balance FROM public.players WHERE id = c) <> 0 THEN RAISE EXCEPTION 'undo balances'; END IF;
  IF (SELECT profit FROM public.bets WHERE market_id = m AND player_id = a) IS NOT NULL
    OR (SELECT profit FROM public.bets WHERE market_id = successor AND player_id = a) <> 0 THEN RAISE EXCEPTION 'undo bets'; END IF;
  SELECT count(*) INTO ledger_count FROM public.ledger;
  IF public.kennel_undo_latest_score(host_hash, undo_key) <> s OR (SELECT count(*) FROM public.ledger) <> ledger_count THEN RAISE EXCEPTION 'undo retry'; END IF;

  -- Re-settlement after reversal creates a fresh auditable settlement cycle.
  s := public.kennel_record_score(host_hash, 'home', 'goal', gen_random_uuid());
  successor := (s#>>'{activeMarket,id}')::uuid;
  s := public.kennel_undo_latest_score(host_hash, gen_random_uuid());
  IF (SELECT balance FROM public.players WHERE id = a) <> 2200 THEN RAISE EXCEPTION 'second settlement reversal'; END IF;
  key := gen_random_uuid();
  s := public.kennel_market_action(host_hash, 'void_market', key, m, NULL, 'Rehearsal void');
  IF (SELECT balance FROM public.players WHERE id = a) <> 2250
    OR (SELECT balance FROM public.players WHERE id = b) <> 1000 OR (SELECT balance FROM public.players WHERE id = c) <> 1000 THEN RAISE EXCEPTION 'void refunds'; END IF;
  SELECT count(*) INTO ledger_count FROM public.ledger;
  PERFORM public.kennel_market_action(host_hash, 'void_market', key, m, NULL, 'Rehearsal void');
  PERFORM public.kennel_market_action(host_hash, 'void_market', gen_random_uuid(), m, NULL, 'Rehearsal void');
  IF (SELECT count(*) FROM public.ledger) <> ledger_count THEN RAISE EXCEPTION 'void idempotency'; END IF;

  s := public.kennel_market_action(host_hash, 'open_next_goal', gen_random_uuid()); m := (s#>>'{activeMarket,id}')::uuid;
  SELECT id INTO home FROM public.market_options WHERE market_id = m AND option_key = 'home';
  PERFORM public.kennel_place_bet(a_hash, m, home, 100, gen_random_uuid());
  s := public.kennel_record_score(host_hash, 'away', 'goal', gen_random_uuid());
  IF (SELECT status FROM public.markets WHERE id = m) <> 'void' OR (SELECT balance FROM public.players WHERE id = a) <> 2250 THEN RAISE EXCEPTION 'no winning pool refund'; END IF;
  PERFORM public.kennel_undo_latest_score(host_hash, gen_random_uuid());
  IF (SELECT balance FROM public.players WHERE id = a) <> 2150 THEN RAISE EXCEPTION 'refund reversal'; END IF;
  s := public.kennel_record_score(host_hash, 'home', 'goal', gen_random_uuid());
  IF (SELECT profit FROM public.bets WHERE market_id = m AND player_id = a) <> 0 OR (SELECT payout FROM public.bets WHERE market_id = m AND player_id = a) <> 100 THEN RAISE EXCEPTION 'one-sided winner'; END IF;
  m := (s#>>'{activeMarket,id}')::uuid;
  SELECT id INTO home FROM public.market_options WHERE market_id = m AND option_key = 'home';
  PERFORM public.kennel_place_bet(a_hash, m, home, 50, gen_random_uuid());
  s := public.kennel_end_quarter(host_hash, gen_random_uuid());
  IF s->'activeMarket' <> 'null'::jsonb OR (SELECT status FROM public.markets WHERE id = m) <> 'void'
    OR NOT EXISTS (SELECT 1 FROM public.quarter_results WHERE quarter = 1) THEN RAISE EXCEPTION 'quarter end'; END IF;
  SELECT quarter_ladder INTO frozen FROM public.quarter_results WHERE quarter = 1;
  IF frozen <> public.kennel_ladder(1) THEN RAISE EXCEPTION 'frozen ladder'; END IF;
  BEGIN PERFORM public.kennel_undo_latest_score(host_hash, gen_random_uuid()); RAISE EXCEPTION 'settled quarter undo accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'A settled quarter cannot be changed' THEN RAISE; END IF; END;
  s := public.kennel_start_quarter(host_hash, 2, gen_random_uuid());
  IF (s#>>'{activeMarket,quarter}')::integer <> 2 OR (SELECT quarter_ladder FROM public.quarter_results WHERE quarter = 1) <> frozen THEN RAISE EXCEPTION 'Q2 opening / frozen Q1'; END IF;

  IF EXISTS (SELECT 1 FROM public.players p WHERE p.balance <> (SELECT COALESCE(sum(amount),0) FROM public.ledger WHERE player_id = p.id)) THEN RAISE EXCEPTION 'ledger balance reconciliation'; END IF;
  IF EXISTS (SELECT 1 FROM public.market_options o WHERE o.pool_bones <> (SELECT COALESCE(sum(stake),0) FROM public.bets WHERE market_id = o.market_id AND option_id = o.id)) THEN RAISE EXCEPTION 'pool reconciliation'; END IF;
  IF EXISTS (SELECT 1 FROM public.ledger r JOIN public.ledger l ON l.id = r.reversal_of_id WHERE r.amount <> -l.amount OR r.kind <> l.kind OR r.player_id <> l.player_id) THEN RAISE EXCEPTION 'reversal reconciliation'; END IF;
  IF EXISTS (SELECT 1 FROM public.markets m WHERE m.status = 'settled' AND
    (SELECT COALESCE(sum(payout),0) FROM public.bets WHERE market_id = m.id) + m.settlement_dust_bones
      <> m.settlement_winning_pool_bones::bigint + m.settlement_losing_pool_bones) THEN RAISE EXCEPTION 'settlement conservation'; END IF;
  BEGIN UPDATE public.ledger SET amount = amount + 1 WHERE player_id = a; RAISE EXCEPTION 'ledger update accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Bones activity is append-only' THEN RAISE; END IF; END;
  BEGIN DELETE FROM public.ledger WHERE player_id = a; RAISE EXCEPTION 'ledger delete accepted';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'Bones activity is append-only' THEN RAISE; END IF; END;
  IF EXISTS (SELECT 1 FROM pg_class WHERE oid IN ('public.markets'::regclass,'public.market_options'::regclass,'public.bets'::regclass,'public.ledger'::regclass) AND NOT relrowsecurity) THEN RAISE EXCEPTION 'RLS missing'; END IF;
  IF has_table_privilege('anon','public.ledger','SELECT') OR has_table_privilege('authenticated','public.bets','INSERT')
    OR has_function_privilege('anon','public.kennel_place_bet(text,uuid,uuid,integer,uuid)','EXECUTE') THEN RAISE EXCEPTION 'client access'; END IF;

  RAISE EXCEPTION 'PHASE_TWO_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
