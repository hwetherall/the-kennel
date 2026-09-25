-- Grand Final assertions: joining by board name, and Studs v Spuds end to end.
--
-- Run by scripts/verify-phase-three.mjs, which prepends the unapplied migrations
-- so everything rolls back. Drives the real host functions, the way the console
-- will hit them.
DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  a_hash text := repeat('a', 32) || suffix;
  b_hash text := repeat('b', 32) || suffix;
  c_hash text := repeat('c', 32) || suffix;
  d_hash text := repeat('d', 32) || suffix;
  e_hash text := repeat('e', 32) || suffix;
  a uuid; b uuid; c uuid; d uuid;
  jackson uuid; draper uuid; cox uuid; fort uuid; bolton uuid; bailey uuid;
  batch uuid; purchase uuid;
  m1 uuid; m2 uuid; m3 uuid; q1s1 uuid; q1s2 uuid; q2s1 uuid;
  opt uuid; s jsonb; ts timestamptz; bal integer; receipt uuid := gen_random_uuid();
BEGIN
  IF EXISTS (SELECT 1 FROM public.markets WHERE status IN ('draft','open','locked'))
    OR EXISTS (SELECT 1 FROM public.quarter_results) OR EXISTS (SELECT 1 FROM public.score_events WHERE voided_at IS NULL) THEN
    RAISE EXCEPTION 'Use an idle rehearsal branch with no active scores, markets or quarter results';
  END IF;
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');
  UPDATE public.game_state SET period_status = 'pre_match', quarter = 1, betting_paused = false,
    home_goals = 0, home_behinds = 0, home_points = 0, away_goals = 0, away_behinds = 0, away_points = 0 WHERE id = 1;

  ---------------------------------------------------------------------------
  -- 1. Joining by picking a name from the squares board.
  ---------------------------------------------------------------------------
  INSERT INTO public.square_import_batches(checksum, source_name) VALUES('test-' || suffix, 'test')
    RETURNING id INTO batch;
  INSERT INTO public.squares_purchases(batch_id, source_ref, purchaser_name, purchaser_email, squares_count)
    VALUES(batch, 'r1', 'Board Person ' || suffix, '', 2) RETURNING id INTO purchase;

  BEGIN
    PERFORM public.kennel_join_player('board person ' || suffix, '', e_hash);
    RAISE EXCEPTION 'a free nickname impersonated a board name';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'That name is on the squares board. Pick it from the list.' THEN RAISE; END IF;
  END;

  s := public.kennel_join_player('', '', d_hash, purchase);
  d := (s#>>'{player,id}')::uuid;
  IF s#>>'{player,nickname}' <> 'Board Person ' || suffix OR (s#>>'{player,squaresCount}')::int <> 2
    OR (s#>>'{player,balance}')::int <> 1500 THEN
    RAISE EXCEPTION 'claiming a board name should take its name, squares and bonus Bones: %', s->'player';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s->'boardNames') n
    WHERE (n->>'purchaseId')::uuid = purchase AND (n->>'claimed')::boolean) THEN
    RAISE EXCEPTION 'a claimed board name should show as claimed';
  END IF;

  BEGIN
    PERFORM public.kennel_join_player('', '', e_hash, purchase);
    RAISE EXCEPTION 'a board name was claimed twice';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'That name has already been claimed' THEN RAISE; END IF;
  END;

  -- Rejoining with the same session is a no-op, not a second claim.
  s := public.kennel_join_player('', '', d_hash, purchase);
  IF (s#>>'{player,id}')::uuid <> d THEN RAISE EXCEPTION 'a rejoin should return the same player'; END IF;

  s := public.kennel_join_player('SA-' || suffix, '', a_hash); a := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('SB-' || suffix, '', b_hash); b := (s#>>'{player,id}')::uuid;
  s := public.kennel_join_player('SC-' || suffix, '', c_hash); c := (s#>>'{player,id}')::uuid;

  ---------------------------------------------------------------------------
  -- 2. Athletes, entered by name with one identity each.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_ensure_athletes(host_hash, jsonb_build_array(
    jsonb_build_object('name', 'Jackson ' || suffix, 'team', 'FRE'),
    jsonb_build_object('name', 'Draper ' || suffix, 'team', 'BRI'),
    jsonb_build_object('name', 'Cox ' || suffix, 'team', 'FRE'),
    jsonb_build_object('name', 'Fort ' || suffix, 'team', 'BRI'),
    jsonb_build_object('name', 'Bolton ' || suffix, 'team', 'FRE'),
    jsonb_build_object('name', 'Bailey ' || suffix, 'team', 'BRI')), gen_random_uuid());
  -- The same name again, differently cased, is the same athlete.
  PERFORM public.kennel_ensure_athletes(host_hash, jsonb_build_array(
    jsonb_build_object('name', '  jackson ' || suffix || ' ', 'team', 'FRE')), gen_random_uuid());
  IF (SELECT count(*) FROM public.athletes WHERE lower(display_name) = lower('Jackson ' || suffix)) <> 1 THEN
    RAISE EXCEPTION 'a re-entered athlete created a duplicate identity';
  END IF;
  SELECT id INTO jackson FROM public.athletes WHERE display_name = 'Jackson ' || suffix;
  SELECT id INTO draper FROM public.athletes WHERE display_name = 'Draper ' || suffix;
  SELECT id INTO cox FROM public.athletes WHERE display_name = 'Cox ' || suffix;
  SELECT id INTO fort FROM public.athletes WHERE display_name = 'Fort ' || suffix;
  SELECT id INTO bolton FROM public.athletes WHERE display_name = 'Bolton ' || suffix;
  SELECT id INTO bailey FROM public.athletes WHERE display_name = 'Bailey ' || suffix;

  ---------------------------------------------------------------------------
  -- 3. Configuration.
  ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.kennel_configure_studs_matchup(host_hash, 1, 1, 'Ruck Round', 'hitouts', jackson, jackson, gen_random_uuid());
    RAISE EXCEPTION 'a matchup against itself was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Choose two different athletes' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.kennel_configure_studs_matchup(host_hash, 1, 4, 'Ruck Round', 'hitouts', jackson, draper, gen_random_uuid());
    RAISE EXCEPTION 'a fourth slot was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'A matchup needs a quarter from 1 to 4 and a slot from 1 to 3' THEN RAISE; END IF;
  END;

  PERFORM public.kennel_configure_studs_matchup(host_hash, 1, 1, 'Ruck Round', 'hitouts', jackson, draper, gen_random_uuid());
  PERFORM public.kennel_configure_studs_matchup(host_hash, 1, 2, 'Ruck Round', 'hitouts', cox, fort, gen_random_uuid());
  PERFORM public.kennel_configure_studs_matchup(host_hash, 2, 1, 'Forwards Round', 'disposals', bolton, bailey, gen_random_uuid());
  -- A removable spare, to prove removal before opening.
  PERFORM public.kennel_configure_studs_matchup(host_hash, 2, 2, 'Forwards Round', 'disposals', cox, bailey, gen_random_uuid());
  PERFORM public.kennel_configure_studs_matchup(host_hash, 2, 2, 'Forwards Round', 'disposals', NULL, NULL, gen_random_uuid());
  IF EXISTS (SELECT 1 FROM public.studs_matchups WHERE quarter = 2 AND slot = 2) THEN
    RAISE EXCEPTION 'removing an unopened matchup failed';
  END IF;
  SELECT id INTO q1s1 FROM public.studs_matchups WHERE quarter = 1 AND slot = 1;
  SELECT id INTO q1s2 FROM public.studs_matchups WHERE quarter = 1 AND slot = 2;
  SELECT id INTO q2s1 FROM public.studs_matchups WHERE quarter = 2 AND slot = 1;
  IF EXISTS (SELECT 1 FROM public.studs_matchups WHERE quarter = 1 AND (baseline_a <> 0 OR baseline_b <> 0)) THEN
    RAISE EXCEPTION 'Q1 baselines must be zero';
  END IF;
  IF (SELECT baseline_a FROM public.studs_matchups WHERE id = q2s1) IS NOT NULL THEN
    RAISE EXCEPTION 'a later quarter must not invent a baseline';
  END IF;

  ---------------------------------------------------------------------------
  -- 4. Pre-match opening: Q1 only.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_open_studs(host_hash, gen_random_uuid());
  SELECT market_id INTO m1 FROM public.studs_matchups WHERE id = q1s1;
  SELECT market_id INTO m2 FROM public.studs_matchups WHERE id = q1s2;
  IF m1 IS NULL OR m2 IS NULL OR (SELECT market_id FROM public.studs_matchups WHERE id = q2s1) IS NOT NULL THEN
    RAISE EXCEPTION 'pre-match should open exactly the Q1 matchups';
  END IF;
  IF EXISTS (SELECT 1 FROM public.markets WHERE id IN (m1, m2) AND (status <> 'open' OR lock_strategy <> 'bounce'
    OR locks_at IS NOT NULL OR quarter <> 1 OR NOT counts_toward_quarter_prize)) THEN
    RAISE EXCEPTION 'a Studs market has the wrong shape';
  END IF;
  BEGIN
    PERFORM public.kennel_configure_studs_matchup(host_hash, 1, 1, 'Ruck Round', 'hitouts', jackson, fort, gen_random_uuid());
    RAISE EXCEPTION 'an open matchup was reconfigured';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Studs matchups can only change before they open' THEN RAISE; END IF;
  END;

  s := public.kennel_public_snapshot();
  IF jsonb_array_length(s->'kennelMarkets') <> 2 THEN
    RAISE EXCEPTION 'the public snapshot should list the two open Q1 matchups';
  END IF;
  IF (s->'kennelMarkets'->0->'studs'->>'stat') <> 'hitouts'
    OR (s->'kennelMarkets'->0->'options'->0->>'teamLabel') <> 'FRE' THEN
    RAISE EXCEPTION 'a Studs market snapshot should carry its stat and athlete teams';
  END IF;

  ---------------------------------------------------------------------------
  -- 5. Stakes during the break, then the bounce locks them.
  ---------------------------------------------------------------------------
  SELECT id INTO opt FROM public.market_options WHERE market_id = m1 AND option_key = 'athlete_a';
  PERFORM public.kennel_place_bet(a_hash, m1, opt, 100, gen_random_uuid());
  SELECT id INTO opt FROM public.market_options WHERE market_id = m1 AND option_key = 'athlete_b';
  PERFORM public.kennel_place_bet(b_hash, m1, opt, 300, gen_random_uuid());
  SELECT id INTO opt FROM public.market_options WHERE market_id = m2 AND option_key = 'athlete_b';
  PERFORM public.kennel_place_bet(a_hash, m2, opt, 50, gen_random_uuid());
  SELECT id INTO opt FROM public.market_options WHERE market_id = m2 AND option_key = 'athlete_a';
  PERFORM public.kennel_place_bet(c_hash, m2, opt, 50, gen_random_uuid());

  s := public.kennel_player_snapshot(a_hash);
  IF jsonb_array_length(s->'positions') <> 2 THEN
    RAISE EXCEPTION 'a guest should see one position per Studs market';
  END IF;

  PERFORM public.kennel_start_quarter(host_hash, 1, gen_random_uuid());
  IF EXISTS (SELECT 1 FROM public.markets WHERE id IN (m1, m2) AND status <> 'locked') THEN
    RAISE EXCEPTION 'the Q1 bounce should lock the Q1 matchups';
  END IF;
  BEGIN
    PERFORM public.kennel_place_bet(c_hash, m1, opt, 10, gen_random_uuid());
    RAISE EXCEPTION 'a Studs market took a stake during play';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Market has locked' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.kennel_open_studs(host_hash, gen_random_uuid());
    RAISE EXCEPTION 'Studs opened during live play';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Studs matchups open during a break or before the first bounce' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.kennel_settle_studs(host_hash, q1s1, 5, 3, gen_random_uuid());
    RAISE EXCEPTION 'a matchup settled before its siren';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Settle this matchup after its quarter siren' THEN RAISE; END IF;
  END;

  ---------------------------------------------------------------------------
  -- 6. The siren: Squares sealed, ladder held for Studs, Q2 matchups open.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_end_quarter(host_hash, gen_random_uuid());
  IF (SELECT ladder_finalized_at FROM public.quarter_results WHERE quarter = 1) IS NOT NULL THEN
    RAISE EXCEPTION 'the Q1 ladder must wait for its Studs results';
  END IF;
  SELECT market_id INTO m3 FROM public.studs_matchups WHERE id = q2s1;
  IF m3 IS NULL OR (SELECT status FROM public.markets WHERE id = m3) <> 'open' THEN
    RAISE EXCEPTION 'the Q1 siren should open the Q2 matchups';
  END IF;

  ---------------------------------------------------------------------------
  -- 7. Settle Q1: a winner, then a tie.
  ---------------------------------------------------------------------------
  -- Jackson 7 hit-outs, Draper 5. A's 100 on Jackson takes B's 300: payout 400.
  PERFORM public.kennel_settle_studs(host_hash, q1s1, 7, 5, receipt);
  SELECT balance INTO bal FROM public.players WHERE id = a;
  IF (SELECT profit FROM public.bets WHERE market_id = m1 AND player_id = a) <> 300
    OR (SELECT profit FROM public.bets WHERE market_id = m1 AND player_id = b) <> -300 THEN
    RAISE EXCEPTION 'the Studs winner was not paid parimutuel';
  END IF;
  IF (SELECT ladder_finalized_at FROM public.quarter_results WHERE quarter = 1) IS NOT NULL THEN
    RAISE EXCEPTION 'the Q1 ladder must wait for its last matchup';
  END IF;

  -- The same request again returns its receipt; a new one is refused. No double pay.
  PERFORM public.kennel_settle_studs(host_hash, q1s1, 7, 5, receipt);
  BEGIN
    PERFORM public.kennel_settle_studs(host_hash, q1s1, 2, 9, gen_random_uuid());
    RAISE EXCEPTION 'a resolved matchup was settled again';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This matchup is already resolved' THEN RAISE; END IF;
  END;
  IF (SELECT balance FROM public.players WHERE id = a) <> bal THEN
    RAISE EXCEPTION 'settling twice changed a balance';
  END IF;

  -- Cox 4, Fort 4: level on the quarter, so every stake is refunded.
  PERFORM public.kennel_settle_studs(host_hash, q1s2, 4, 4, gen_random_uuid());
  IF (SELECT status FROM public.markets WHERE id = m2) <> 'void'
    OR EXISTS (SELECT 1 FROM public.bets WHERE market_id = m2 AND profit <> 0) THEN
    RAISE EXCEPTION 'a tie must void and refund';
  END IF;
  SELECT ladder_finalized_at INTO ts FROM public.quarter_results WHERE quarter = 1;
  IF ts IS NULL THEN RAISE EXCEPTION 'the Q1 ladder should finalize after its last matchup'; END IF;
  IF (SELECT (row->>'profit')::int FROM public.quarter_results r,
      jsonb_array_elements(r.quarter_ladder) row WHERE r.quarter = 1 AND (row->>'playerId')::uuid = a) <> 300 THEN
    RAISE EXCEPTION 'the stored Q1 standings should include Studs profit';
  END IF;

  ---------------------------------------------------------------------------
  -- 8. Q2: baselines at the break, and the quarter delta decides it.
  ---------------------------------------------------------------------------
  BEGIN
    PERFORM public.kennel_set_studs_baselines(host_hash, q1s1, 1, 1, gen_random_uuid());
    RAISE EXCEPTION 'a resolved matchup took new baselines';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'This matchup is already resolved' THEN RAISE; END IF;
  END;
  PERFORM public.kennel_set_studs_baselines(host_hash, q2s1, 10, 12, gen_random_uuid());
  SELECT id INTO opt FROM public.market_options WHERE market_id = m3 AND option_key = 'athlete_b';
  PERFORM public.kennel_place_bet(b_hash, m3, opt, 100, gen_random_uuid());
  SELECT id INTO opt FROM public.market_options WHERE market_id = m3 AND option_key = 'athlete_a';
  PERFORM public.kennel_place_bet(c_hash, m3, opt, 100, gen_random_uuid());

  PERFORM public.kennel_start_quarter(host_hash, 2, gen_random_uuid());
  PERFORM public.kennel_end_quarter(host_hash, gen_random_uuid());
  BEGIN
    PERFORM public.kennel_settle_studs(host_hash, q2s1, 9, 20, gen_random_uuid());
    RAISE EXCEPTION 'a total below its baseline was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'A cumulative total cannot be lower than its baseline' THEN RAISE; END IF;
  END;
  -- Bolton 10 -> 15 (5 this quarter), Bailey 12 -> 16 (4). Bolton wins on the
  -- quarter even though Bailey has the larger game total.
  PERFORM public.kennel_settle_studs(host_hash, q2s1, 15, 16, gen_random_uuid());
  IF (SELECT profit FROM public.bets WHERE market_id = m3 AND player_id = c) <> 100 THEN
    RAISE EXCEPTION 'Studs must be decided by the quarter delta, not the game total';
  END IF;
  IF (SELECT ladder_finalized_at FROM public.quarter_results WHERE quarter = 2) IS NULL THEN
    RAISE EXCEPTION 'the Q2 ladder should finalize once its only matchup resolves';
  END IF;

  ---------------------------------------------------------------------------
  -- 9. A quarter with no Studs finalizes its ladder at the siren, as in Phase 2.
  ---------------------------------------------------------------------------
  PERFORM public.kennel_start_quarter(host_hash, 3, gen_random_uuid());
  PERFORM public.kennel_end_quarter(host_hash, gen_random_uuid());
  IF (SELECT ladder_finalized_at FROM public.quarter_results WHERE quarter = 3) IS NULL THEN
    RAISE EXCEPTION 'a quarter without Studs should finalize at the siren';
  END IF;

  ---------------------------------------------------------------------------
  -- 10. Invariants.
  ---------------------------------------------------------------------------
  IF EXISTS (SELECT 1 FROM public.players p WHERE p.balance <> (SELECT COALESCE(sum(amount),0) FROM public.ledger WHERE player_id = p.id)) THEN
    RAISE EXCEPTION 'ledger balance reconciliation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.market_options o WHERE o.pool_bones <> (SELECT COALESCE(sum(stake),0) FROM public.bets WHERE market_id = o.market_id AND option_id = o.id)) THEN
    RAISE EXCEPTION 'pool reconciliation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.markets m WHERE m.type = 'studs_v_spuds' AND m.status = 'settled'
    AND m.settlement_losing_pool_bones < (SELECT COALESCE(sum(profit),0) FROM public.bets WHERE market_id = m.id AND profit > 0)) THEN
    RAISE EXCEPTION 'a Studs settlement paid out more than its losing pool';
  END IF;

  RAISE EXCEPTION 'GRAND_FINAL_STUDS_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
