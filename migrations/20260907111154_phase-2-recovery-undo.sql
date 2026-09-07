-- Approved recovery rule: undo unwinds all later Next Goal markets.
-- Earlier migration files remain immutable deployment history.
CREATE OR REPLACE FUNCTION public.kennel_undo_latest_score(
  p_host_token_hash text,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  game public.game_state%ROWTYPE;
  latest public.score_events%ROWTYPE;
  previous public.score_events%ROWTYPE;
  later_market public.markets%ROWTYPE;
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO game FROM public.game_state WHERE id = 1 FOR UPDATE;

  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'undo_latest_score' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;

  SELECT * INTO latest FROM public.score_events
  WHERE voided_at IS NULL ORDER BY sequence DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'There is no score to undo'; END IF;
  IF EXISTS (SELECT 1 FROM public.quarter_results WHERE quarter = latest.quarter) THEN
    RAISE EXCEPTION 'A settled quarter cannot be changed';
  END IF;

  IF latest.opened_market_id IS NOT NULL THEN
    -- Newest first: recover Bones spent in later markets before removing the
    -- credits that funded them. The shared game lock excludes concurrent stakes
    -- and host mutations for the entire reversal.
    FOR later_market IN
      SELECT * FROM public.markets
      WHERE type = 'next_goal' AND quarter = latest.quarter
        AND sequence >= (SELECT sequence FROM public.markets WHERE id = latest.opened_market_id)
      ORDER BY sequence DESC FOR UPDATE
    LOOP
      -- A void already returned every stake. Reversing its refunds could remove
      -- Bones subsequently staked on an earlier market restored by another undo.
      IF later_market.status = 'void' THEN CONTINUE; END IF;
      IF later_market.settled_at IS NOT NULL THEN
        PERFORM public.kennel_reverse_market_settlement(later_market.id, p_request_id);
      END IF;
      PERFORM public.kennel_finish_market(later_market.id, NULL, 'Goal undone', p_request_id);
    END LOOP;
  END IF;
  IF latest.settled_market_id IS NOT NULL THEN
    PERFORM public.kennel_reverse_market_settlement(latest.settled_market_id, p_request_id);
  END IF;

  UPDATE public.score_events SET voided_at = now() WHERE id = latest.id;
  SELECT * INTO previous FROM public.score_events
  WHERE voided_at IS NULL ORDER BY sequence DESC LIMIT 1;

  UPDATE public.game_state SET
    home_goals = COALESCE(previous.home_goals, 0),
    home_behinds = COALESCE(previous.home_behinds, 0),
    home_points = COALESCE(previous.home_points, 0),
    away_goals = COALESCE(previous.away_goals, 0),
    away_behinds = COALESCE(previous.away_behinds, 0),
    away_points = COALESCE(previous.away_points, 0),
    last_score_event_id = previous.id,
    version = version + 1,
    updated_at = now()
  WHERE id = 1;

  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts (action, idempotency_key, actor_fingerprint, response)
  VALUES ('undo_latest_score', p_request_id, p_host_token_hash, result);
  PERFORM public.kennel_emit_event('score_undone', jsonb_build_object(
    'version', result #> '{game,version}', 'voidedScoreEventId', latest.id
  ));
  RETURN result;
END;
$$;
