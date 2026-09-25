-- Live score assist: the latest score from Squiggle's live feed, for the host.
--
-- The feed never scores. It stores one row, the feed's latest running totals,
-- and the host console turns any difference from the app's own score into a
-- one-tap confirmation that goes through kennel_record_score like any other tap.
-- If the feed lags, stops or reverses, the app's score is untouched.

CREATE TABLE public.score_feed (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  source_game_id integer NOT NULL,
  home_goals integer NOT NULL CHECK (home_goals >= 0),
  home_behinds integer NOT NULL CHECK (home_behinds >= 0),
  away_goals integer NOT NULL CHECK (away_goals >= 0),
  away_behinds integer NOT NULL CHECK (away_behinds >= 0),
  time_label text CHECK (time_label IS NULL OR length(time_label) <= 40),
  complete integer CHECK (complete BETWEEN 0 AND 100),
  received_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.score_feed ENABLE ROW LEVEL SECURITY;
CREATE POLICY "client access denied" ON public.score_feed
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);
REVOKE ALL ON public.score_feed FROM PUBLIC, anon, authenticated;

-- Host-authenticated, so only the feed script holding a host session can write.
-- No receipt: the latest reading simply replaces the previous one.
CREATE FUNCTION public.kennel_record_feed(p_host_token_hash text, p_source_game_id integer,
  p_home_goals integer, p_home_behinds integer, p_away_goals integer, p_away_behinds integer,
  p_time_label text, p_complete integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  IF p_source_game_id IS NULL OR p_home_goals IS NULL OR p_home_behinds IS NULL
    OR p_away_goals IS NULL OR p_away_behinds IS NULL
    OR LEAST(p_home_goals, p_home_behinds, p_away_goals, p_away_behinds) < 0 THEN
    RAISE EXCEPTION 'Invalid feed reading';
  END IF;
  INSERT INTO public.score_feed(id, source_game_id, home_goals, home_behinds, away_goals, away_behinds,
    time_label, complete, received_at)
  VALUES(1, p_source_game_id, p_home_goals, p_home_behinds, p_away_goals, p_away_behinds,
    left(p_time_label, 40), p_complete, clock_timestamp())
  ON CONFLICT (id) DO UPDATE SET source_game_id = EXCLUDED.source_game_id,
    home_goals = EXCLUDED.home_goals, home_behinds = EXCLUDED.home_behinds,
    away_goals = EXCLUDED.away_goals, away_behinds = EXCLUDED.away_behinds,
    time_label = EXCLUDED.time_label, complete = EXCLUDED.complete, received_at = EXCLUDED.received_at;
  PERFORM public.kennel_emit_event('feed_updated', '{}'::jsonb);
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- The host snapshot gains the feed reading; guests never see it.
CREATE OR REPLACE FUNCTION public.kennel_host_snapshot(p_host_token_hash text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  RETURN public.kennel_public_snapshot() || jsonb_build_object(
    'quarterLadder', public.kennel_ladder((SELECT quarter FROM public.game_state WHERE id = 1)),
    'topDogLadder', public.kennel_ladder(),
    'markets', (SELECT COALESCE(jsonb_agg(public.kennel_market_snapshot(m.id) ORDER BY m.sequence DESC), '[]'::jsonb)
      FROM (SELECT id, sequence FROM public.markets ORDER BY sequence DESC LIMIT 20) m),
    'players', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', player.id,
        'nickname', player.nickname,
        'squaresCount', player.squares_count,
        'isSquareHolder', player.is_square_holder, 'balance', player.balance
      ) ORDER BY lower(player.nickname))
      FROM public.players AS player
    ), '[]'::jsonb),
    'purchases', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', purchase.id,
        'purchaserName', purchase.purchaser_name,
        'purchaserEmail', purchase.purchaser_email,
        'squaresCount', purchase.squares_count,
        'linkedPlayerId', purchase.linked_player_id
      ) ORDER BY lower(purchase.purchaser_name), purchase.id)
      FROM public.squares_purchases AS purchase
    ), '[]'::jsonb),
    'athletes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.display_name, 'team', a.team_label)
        ORDER BY a.team_label NULLS LAST, lower(a.display_name))
      FROM public.athletes a
    ), '[]'::jsonb),
    'studsMatchups', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'quarter', s.quarter, 'slot', s.slot, 'roundLabel', s.round_label, 'stat', s.stat,
        'athleteAId', s.athlete_a_id, 'athleteAName', a.display_name, 'athleteATeam', a.team_label,
        'athleteBId', s.athlete_b_id, 'athleteBName', b.display_name, 'athleteBTeam', b.team_label,
        'baselineA', s.baseline_a, 'baselineB', s.baseline_b, 'endingA', s.ending_a, 'endingB', s.ending_b,
        'marketId', s.market_id, 'marketStatus', m.status, 'resolvedAt', s.resolved_at
      ) ORDER BY s.quarter, s.slot)
      FROM public.studs_matchups s
      JOIN public.athletes a ON a.id = s.athlete_a_id
      JOIN public.athletes b ON b.id = s.athlete_b_id
      LEFT JOIN public.markets m ON m.id = s.market_id
    ), '[]'::jsonb),
    'futures', COALESCE((
      SELECT jsonb_agg(public.kennel_market_snapshot(m.id) ORDER BY m.type DESC)
      FROM public.markets m WHERE m.type IN ('futures_winner', 'futures_norm_smith')
    ), '[]'::jsonb),
    'scoreFeed', (SELECT jsonb_build_object('sourceGameId', f.source_game_id,
      'homeGoals', f.home_goals, 'homeBehinds', f.home_behinds,
      'awayGoals', f.away_goals, 'awayBehinds', f.away_behinds,
      'timeLabel', f.time_label, 'complete', f.complete, 'receivedAt', f.received_at)
      FROM public.score_feed f WHERE f.id = 1)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.kennel_record_feed(text, integer, integer, integer, integer, integer, text, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_host_snapshot(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.kennel_record_feed(text, integer, integer, integer, integer, integer, text, integer) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_host_snapshot(text) TO project_admin;
