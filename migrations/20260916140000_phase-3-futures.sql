-- Phase 3, step 3: the two Futures, end to end.
--
-- Match winner and Norm Smith. Both are configured before the first bounce, lock
-- at the Q1 bounce by the step 1 bounce rule, and settle once after full time.
--
-- No payout arithmetic is written here. kennel_finish_market already settles any
-- number of options exactly, discards and audits dust, voids a zero winning pool,
-- and returns early when a market is already settled. Norm Smith is simply the
-- first market to use more than two options.

-- ---------------------------------------------------------------------------
-- The generic recovery action becomes Next Goal only
-- ---------------------------------------------------------------------------
--
-- Unchanged from Phase 2 except for the market-type guard marked below. A host
-- must not be able to bypass Futures timing or full-time confirmation by sending
-- a Future's id to settle_market.
CREATE OR REPLACE FUNCTION public.kennel_market_action(p_host_token_hash text, p_action text, p_request_id uuid,
  p_market_id uuid DEFAULT NULL::uuid, p_winning_option_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text,
  p_lock_seconds integer DEFAULT 90)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE m public.markets%ROWTYPE; cached jsonb; result jsonb; market_id uuid;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  IF p_action IS NULL OR p_action NOT IN ('lock_market','settle_market','void_market','open_next_goal') THEN
    RAISE EXCEPTION 'Unknown market action';
  END IF;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = p_action
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  IF p_action = 'open_next_goal' THEN
    market_id := public.kennel_open_next_goal_internal(p_lock_seconds);
  ELSE
    SELECT * INTO m FROM public.markets WHERE id = p_market_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Market not found'; END IF;
    -- The Phase 3 guard. Studs and the Futures carry their own timing and
    -- finalization rules, and their own host actions enforce them.
    IF m.type <> 'next_goal' THEN
      RAISE EXCEPTION 'This market has its own host action';
    END IF;
    market_id := m.id;
    IF p_action = 'lock_market' THEN
      IF m.settled_at IS NOT NULL THEN RAISE EXCEPTION 'Market is already settled or void'; END IF;
      UPDATE public.markets SET status = 'locked', updated_at = clock_timestamp() WHERE id = m.id;
      PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', m.id, 'status', 'locked'));
    ELSIF p_action = 'settle_market' THEN
      IF p_winning_option_id IS NULL THEN RAISE EXCEPTION 'Choose the scoring team'; END IF;
      PERFORM public.kennel_finish_market(m.id, p_winning_option_id, NULL, p_request_id);
    ELSE
      IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'A short void reason is required'; END IF;
      PERFORM public.kennel_finish_market(m.id, NULL, btrim(p_reason), p_request_id);
    END IF;
  END IF;
  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES(p_action, p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Configure both Futures, pre-match only
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.kennel_configure_futures(
  p_host_token_hash text,
  p_match_max_stake integer,
  p_norm_max_stake integer,
  p_candidate_ids uuid[],
  p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  g public.game_state%ROWTYPE; e public.event_config%ROWTYPE;
  cached jsonb; result jsonb; existing_status text;
  winner_id uuid; norm_id uuid; candidate uuid; slot integer;
  match_cap integer := COALESCE(p_match_max_stake, 200);
  norm_cap integer := COALESCE(p_norm_max_stake, 200);
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO g FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'configure_futures'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  IF g.period_status <> 'pre_match' THEN
    RAISE EXCEPTION 'Futures can only be configured before the first bounce';
  END IF;
  IF match_cap NOT BETWEEN 1 AND 1000000 OR norm_cap NOT BETWEEN 1 AND 1000000 THEN
    RAISE EXCEPTION 'A stake cap must be a positive number of Bones';
  END IF;
  IF p_candidate_ids IS NULL OR array_length(p_candidate_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'Name at least one Norm Smith candidate';
  END IF;
  IF array_length(p_candidate_ids, 1) <> (SELECT count(DISTINCT c) FROM unnest(p_candidate_ids) AS c) THEN
    RAISE EXCEPTION 'A candidate can only be listed once';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_candidate_ids) AS c
    WHERE NOT EXISTS (SELECT 1 FROM public.athletes WHERE id = c)) THEN
    RAISE EXCEPTION 'Unknown Norm Smith candidate';
  END IF;

  SELECT * INTO e FROM public.event_config WHERE id = 1;

  ---------------------------------------------------------------------------
  -- Match winner: a two-team market, labelled from the event's team names.
  ---------------------------------------------------------------------------
  SELECT id, status INTO winner_id, existing_status
    FROM public.markets WHERE type = 'futures_winner' FOR UPDATE;
  IF FOUND THEN
    IF existing_status <> 'draft' THEN
      RAISE EXCEPTION 'The match-winner Future is already open and cannot be reconfigured';
    END IF;
    IF EXISTS (SELECT 1 FROM public.bets WHERE market_id = winner_id) THEN
      RAISE EXCEPTION 'The match-winner Future already carries stakes';
    END IF;
    DELETE FROM public.market_options WHERE market_id = winner_id;
    UPDATE public.markets SET max_stake = match_cap, updated_at = clock_timestamp() WHERE id = winner_id;
  ELSE
    INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize, max_stake)
      VALUES('futures_winner', 'Who wins the match?', 'draft', 'bounce', false, match_cap)
      RETURNING id INTO winner_id;
  END IF;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(winner_id, 'home', e.home_team, 0), (winner_id, 'away', e.away_team, 1);

  ---------------------------------------------------------------------------
  -- Norm Smith: the named candidates, plus the catch-all so a surprise winner
  -- never voids the market.
  ---------------------------------------------------------------------------
  SELECT id, status INTO norm_id, existing_status
    FROM public.markets WHERE type = 'futures_norm_smith' FOR UPDATE;
  IF FOUND THEN
    IF existing_status <> 'draft' THEN
      RAISE EXCEPTION 'The Norm Smith Future is already open and cannot be reconfigured';
    END IF;
    IF EXISTS (SELECT 1 FROM public.bets WHERE market_id = norm_id) THEN
      RAISE EXCEPTION 'The Norm Smith Future already carries stakes';
    END IF;
    DELETE FROM public.market_options WHERE market_id = norm_id;
    UPDATE public.markets SET max_stake = norm_cap, updated_at = clock_timestamp() WHERE id = norm_id;
  ELSE
    INSERT INTO public.markets(type, title, status, lock_strategy, counts_toward_quarter_prize, max_stake)
      VALUES('futures_norm_smith', 'Who wins the Norm Smith Medal?', 'draft', 'bounce', false, norm_cap)
      RETURNING id INTO norm_id;
  END IF;

  slot := 0;
  FOREACH candidate IN ARRAY p_candidate_ids LOOP
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      SELECT norm_id, 'athlete:' || a.id::text, a.display_name, slot, a.id
      FROM public.athletes a WHERE a.id = candidate;
    slot := slot + 1;
  END LOOP;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(norm_id, 'any_other_player', 'Any other player', slot);

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('configure_futures', p_request_id, p_host_token_hash, result);
  PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', winner_id));
  PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', norm_id));
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Open both Futures, pre-match only
-- ---------------------------------------------------------------------------
--
-- locks_at stays NULL. These are bounce-locked: start_quarter locks them in the
-- transaction that begins Q1, and no invented far-future date stands in for it.
CREATE FUNCTION public.kennel_open_futures(p_host_token_hash text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  g public.game_state%ROWTYPE; cached jsonb; result jsonb;
  m public.markets%ROWTYPE; future_type text;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO g FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'open_futures'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  -- Belt and braces with the step 1 guard: a bounce market can never open during
  -- live play, and a Future in particular opens only before the match.
  IF g.period_status <> 'pre_match' THEN
    RAISE EXCEPTION 'Futures open before the first bounce only';
  END IF;

  FOREACH future_type IN ARRAY ARRAY['futures_winner','futures_norm_smith'] LOOP
    SELECT * INTO m FROM public.markets WHERE type = future_type FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Configure both Futures before opening them'; END IF;
    IF m.status = 'open' THEN CONTINUE; END IF;
    IF m.status <> 'draft' THEN RAISE EXCEPTION 'This Future can no longer be opened'; END IF;
    IF (SELECT count(*) FROM public.market_options WHERE market_id = m.id) < 2 THEN
      RAISE EXCEPTION 'This Future needs at least two options';
    END IF;
    IF future_type = 'futures_norm_smith' THEN
      IF NOT EXISTS (SELECT 1 FROM public.market_options WHERE market_id = m.id AND athlete_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Name at least one Norm Smith candidate';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.market_options WHERE market_id = m.id AND option_key = 'any_other_player') THEN
        RAISE EXCEPTION 'Norm Smith must offer Any other player';
      END IF;
    END IF;
    UPDATE public.markets SET status = 'open', opens_at = clock_timestamp(), locks_at = NULL,
      updated_at = clock_timestamp() WHERE id = m.id;
    PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', m.id, 'status', 'open'));
  END LOOP;

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('open_futures', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Settle the match winner, after full time
-- ---------------------------------------------------------------------------
--
-- The server derives the winner from its own final score. The host confirms that
-- the match is actually over, including any additional play, by having sealed Q4;
-- the result itself is never typed in. A level score voids and refunds rather than
-- picking a side.
CREATE FUNCTION public.kennel_settle_match_future(p_host_token_hash text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  g public.game_state%ROWTYPE; cached jsonb; result jsonb;
  m public.markets%ROWTYPE; winning_key text; winning_option uuid;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO g FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'settle_match_future'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  -- Full time first, so score undo is already unavailable and no open market can
  -- spend this payout.
  IF g.period_status <> 'final' THEN
    RAISE EXCEPTION 'Seal full time before settling the Futures';
  END IF;

  SELECT * INTO m FROM public.markets WHERE type = 'futures_winner' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no match-winner Future'; END IF;

  IF m.settled_at IS NULL THEN
    IF g.home_points > g.away_points THEN winning_key := 'home';
    ELSIF g.away_points > g.home_points THEN winning_key := 'away';
    ELSE winning_key := NULL;
    END IF;

    IF winning_key IS NULL THEN
      PERFORM public.kennel_finish_market(m.id, NULL, 'The match finished level', p_request_id);
    ELSE
      SELECT id INTO winning_option FROM public.market_options
        WHERE market_id = m.id AND option_key = winning_key;
      IF winning_option IS NULL THEN RAISE EXCEPTION 'The match-winner Future is missing a team option'; END IF;
      PERFORM public.kennel_finish_market(m.id, winning_option, NULL, p_request_id);
    END IF;
  END IF;

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('settle_match_future', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Settle Norm Smith, after full time
-- ---------------------------------------------------------------------------
--
-- The host selects the official recipient, from the configured candidates or the
-- catch-all. There is no feed and no automatic lookup, deliberately.
CREATE FUNCTION public.kennel_settle_norm_smith(p_host_token_hash text, p_winning_option_id uuid, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  g public.game_state%ROWTYPE; cached jsonb; result jsonb; m public.markets%ROWTYPE;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO g FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'settle_norm_smith'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  IF g.period_status <> 'final' THEN
    RAISE EXCEPTION 'Seal full time before settling the Futures';
  END IF;

  SELECT * INTO m FROM public.markets WHERE type = 'futures_norm_smith' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no Norm Smith Future'; END IF;

  IF m.settled_at IS NULL THEN
    IF p_winning_option_id IS NULL THEN RAISE EXCEPTION 'Choose the medal recipient'; END IF;
    -- Ownership matters: an option id from another market must never settle this one.
    IF NOT EXISTS (SELECT 1 FROM public.market_options WHERE market_id = m.id AND id = p_winning_option_id) THEN
      RAISE EXCEPTION 'Choose a candidate from this market';
    END IF;
    PERFORM public.kennel_finish_market(m.id, p_winning_option_id, NULL, p_request_id);
  END IF;

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('settle_norm_smith', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Void a Future with a reason
-- ---------------------------------------------------------------------------
--
-- The explicit escape hatch for an unresolvable result, so the host is never
-- pushed into guessing an answer to get past the screen.
CREATE FUNCTION public.kennel_void_future(p_host_token_hash text, p_market_id uuid, p_reason text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cached jsonb; result jsonb; m public.markets%ROWTYPE;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'void_future'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'A short void reason is required';
  END IF;

  SELECT * INTO m FROM public.markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Market not found'; END IF;
  IF m.type NOT IN ('futures_winner','futures_norm_smith') THEN
    RAISE EXCEPTION 'This market has its own host action';
  END IF;

  PERFORM public.kennel_finish_market(m.id, NULL, btrim(p_reason), p_request_id);

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('void_future', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Access boundary: the edge function is the only caller
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.athletes FROM PUBLIC, anon, authenticated;
DO $grants$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT format('public.%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)) AS signature
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
      'kennel_configure_futures','kennel_open_futures','kennel_settle_match_future',
      'kennel_settle_norm_smith','kennel_void_future','kennel_guard_market_option_key'
    )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.signature);
  END LOOP;
END
$grants$;

GRANT EXECUTE ON FUNCTION public.kennel_configure_futures(text, integer, integer, uuid[], uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_open_futures(text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_settle_match_future(text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_settle_norm_smith(text, uuid, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_void_future(text, uuid, text, uuid) TO project_admin;
