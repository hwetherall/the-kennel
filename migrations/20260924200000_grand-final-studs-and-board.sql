-- Grand Final night: pick-your-name joining, Studs v Spuds, and every Kennel
-- market in the snapshots.
--
-- Builds on the three Phase 3 migrations: bounce locking, athletes, and Futures.
-- Studs markets are bounce-locked, so start_quarter already locks them and the
-- live-play guard already keeps them closed during play. Settlement reuses
-- kennel_finish_market; no payout arithmetic is written here.

-- ---------------------------------------------------------------------------
-- Studs v Spuds matchups
-- ---------------------------------------------------------------------------

CREATE TABLE public.studs_matchups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quarter integer NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  slot integer NOT NULL CHECK (slot BETWEEN 1 AND 3),
  round_label text NOT NULL CHECK (length(btrim(round_label)) BETWEEN 1 AND 40),
  stat text NOT NULL DEFAULT 'disposals' CHECK (stat IN ('disposals', 'hitouts')),
  athlete_a_id uuid NOT NULL REFERENCES public.athletes(id) ON DELETE RESTRICT,
  athlete_b_id uuid NOT NULL REFERENCES public.athletes(id) ON DELETE RESTRICT,
  -- Cumulative game-to-date totals at the previous siren, and at this quarter's siren.
  baseline_a integer CHECK (baseline_a >= 0),
  baseline_b integer CHECK (baseline_b >= 0),
  ending_a integer CHECK (ending_a >= 0),
  ending_b integer CHECK (ending_b >= 0),
  market_id uuid UNIQUE REFERENCES public.markets(id),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (quarter, slot),
  CHECK (athlete_a_id <> athlete_b_id),
  CHECK (quarter <> 1 OR (baseline_a = 0 AND baseline_b = 0)),
  CHECK (ending_a IS NULL OR ending_a >= baseline_a),
  CHECK (ending_b IS NULL OR ending_b >= baseline_b),
  CHECK (resolved_at IS NULL OR market_id IS NOT NULL)
);
CREATE INDEX studs_matchups_athlete_a_idx ON public.studs_matchups(athlete_a_id);
CREATE INDEX studs_matchups_athlete_b_idx ON public.studs_matchups(athlete_b_id);

ALTER TABLE public.studs_matchups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "client access denied" ON public.studs_matchups
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);
REVOKE ALL ON public.studs_matchups FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Snapshots
-- ---------------------------------------------------------------------------

-- Adds lockStrategy, each option's athlete team, and the Studs matchup readings.
CREATE OR REPLACE FUNCTION public.kennel_market_snapshot(p_market_id uuid) RETURNS jsonb LANGUAGE sql VOLATILE
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', m.id, 'sequence', m.sequence, 'type', m.type, 'quarter', m.quarter, 'title', m.title,
    'status', CASE WHEN m.status = 'open' AND clock_timestamp() >= m.locks_at THEN 'locked' ELSE m.status END,
    'lockStrategy', m.lock_strategy,
    'opensAt', m.opens_at, 'locksAt', m.locks_at, 'settledAt', m.settled_at,
    'winningOptionId', m.winning_option_id, 'maxStake', m.max_stake,
    'countsTowardQuarterPrize', m.counts_toward_quarter_prize, 'sponsorLabel', m.sponsor_label,
    'voidReason', m.void_reason,
    'betCount', (SELECT count(*) FROM public.bets WHERE market_id = m.id),
    'totalPoolBones', (SELECT COALESCE(sum(pool_bones),0) FROM public.market_options WHERE market_id = m.id),
    'settlement', CASE WHEN m.settled_at IS NOT NULL THEN jsonb_build_object(
      'winningPoolBones', m.settlement_winning_pool_bones, 'losingPoolBones', m.settlement_losing_pool_bones,
      'dustBones', m.settlement_dust_bones) ELSE NULL END,
    'options', (SELECT jsonb_agg(jsonb_build_object('id', o.id, 'marketId', o.market_id,
      'optionKey', o.option_key, 'label', o.label, 'poolBones', o.pool_bones, 'sortOrder', o.sort_order,
      'teamLabel', a.team_label,
      'betCount', (SELECT count(*) FROM public.bets WHERE option_id = o.id AND market_id = m.id)
    ) ORDER BY o.sort_order) FROM public.market_options o
      LEFT JOIN public.athletes a ON a.id = o.athlete_id WHERE o.market_id = m.id),
    'studs', (SELECT jsonb_build_object('matchupId', s.id, 'slot', s.slot, 'roundLabel', s.round_label,
      'stat', s.stat, 'baselineA', s.baseline_a, 'baselineB', s.baseline_b,
      'endingA', s.ending_a, 'endingB', s.ending_b,
      'quarterA', s.ending_a - s.baseline_a, 'quarterB', s.ending_b - s.baseline_b)
      FROM public.studs_matchups s WHERE s.market_id = m.id)
  ) FROM public.markets m WHERE m.id = p_market_id;
$$;

-- Every Kennel market other than Next Goal that guests can see: both Futures and
-- every opened Studs matchup. There are at most thirteen.
CREATE FUNCTION public.kennel_kennel_markets() RETURNS jsonb LANGUAGE sql VOLATILE
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(public.kennel_market_snapshot(m.id) ORDER BY
    CASE m.type WHEN 'futures_winner' THEN 0 WHEN 'futures_norm_smith' THEN 1 ELSE 2 END,
    m.quarter, s.slot, m.sequence), '[]'::jsonb)
  FROM public.markets m LEFT JOIN public.studs_matchups s ON s.market_id = m.id
  WHERE m.type <> 'next_goal' AND m.status <> 'draft';
$$;

CREATE OR REPLACE FUNCTION public.kennel_public_snapshot()
RETURNS jsonb
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'serverNow', clock_timestamp(),
    'event', jsonb_build_object(
      'eventName', event.event_name,
      'eventCode', event.event_code,
      'venue', event.venue,
      'startsAt', event.starts_at,
      'timezone', event.timezone,
      'homeTeam', event.home_team,
      'awayTeam', event.away_team,
      'zeffyUrl', event.zeffy_url
    ),
    'game', jsonb_build_object(
      'quarter', game.quarter,
      'periodStatus', game.period_status,
      'homeGoals', game.home_goals,
      'homeBehinds', game.home_behinds,
      'homePoints', game.home_points,
      'awayGoals', game.away_goals,
      'awayBehinds', game.away_behinds,
      'awayPoints', game.away_points,
      'bettingPaused', game.betting_paused,
      'version', game.version,
      'updatedAt', game.updated_at,
      'canUndo', EXISTS (
        SELECT 1 FROM public.score_events AS score
        WHERE score.voided_at IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM public.quarter_results AS result WHERE result.quarter = score.quarter
          )
      )
    ),
    'grid', jsonb_build_object(
      'rowDigits', grid.row_digits,
      'colDigits', grid.col_digits
    ),
    'squares', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', square.id,
        'rowIndex', square.row_index,
        'colIndex', square.col_index,
        'ownerLabel', COALESCE(player.nickname, purchase.purchaser_name)
      ) ORDER BY square.id)
      FROM public.squares AS square
      LEFT JOIN public.squares_purchases AS purchase ON purchase.id = square.purchase_id
      LEFT JOIN public.players AS player ON player.id = purchase.linked_player_id
    ), '[]'::jsonb),
    'quarterResults', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'quarter', result.quarter,
        'homePoints', result.home_points,
        'awayPoints', result.away_points,
        'winningSquareId', result.winning_square_id,
        'winnerLabel', COALESCE(player.nickname, purchase.purchaser_name),
        'settledAt', result.settled_at,
        'ladderFinalizedAt', result.ladder_finalized_at,
        'quarterLadder', result.quarter_ladder
      ) ORDER BY result.quarter)
      FROM public.quarter_results AS result
      JOIN public.squares AS square ON square.id = result.winning_square_id
      LEFT JOIN public.squares_purchases AS purchase ON purchase.id = square.purchase_id
      LEFT JOIN public.players AS player ON player.id = purchase.linked_player_id
    ), '[]'::jsonb),
    -- The names on the squares board, for joining by picking your own.
    'boardNames', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'purchaseId', purchase.id,
        'name', purchase.purchaser_name,
        'squaresCount', purchase.squares_count,
        'claimed', purchase.linked_player_id IS NOT NULL
      ) ORDER BY lower(purchase.purchaser_name), purchase.id)
      FROM public.squares_purchases AS purchase
    ), '[]'::jsonb)
  ) || jsonb_build_object(
    'activeMarket', public.kennel_market_snapshot((SELECT id FROM public.markets WHERE type = 'next_goal' AND status IN ('draft','open','locked'))),
    'recentMarket', public.kennel_market_snapshot((SELECT id FROM public.markets WHERE settled_at IS NOT NULL ORDER BY sequence DESC LIMIT 1)),
    'kennelMarkets', public.kennel_kennel_markets(),
    'quarterLadder', public.kennel_ladder(game.quarter, NULL, 5),
    'topDogLadder', public.kennel_ladder(NULL, NULL, 5)
  )
  FROM public.event_config AS event
  CROSS JOIN public.game_state AS game
  CROSS JOIN public.grid_config AS grid
  WHERE event.id = 1 AND game.id = 1 AND grid.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.kennel_player_snapshot(p_token_hash text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  player_row public.players%ROWTYPE;
BEGIN
  SELECT * INTO player_row
  FROM public.players
  WHERE session_token_hash = p_token_hash;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player session is no longer valid';
  END IF;

  RETURN public.kennel_public_snapshot() || jsonb_build_object(
    'player', jsonb_build_object(
      'id', player_row.id,
      'nickname', player_row.nickname,
      'squaresCount', player_row.squares_count,
      'isSquareHolder', player_row.is_square_holder,
      'balance', player_row.balance,
      'quarterRank', (SELECT value->'rank' FROM jsonb_array_elements(public.kennel_ladder((SELECT quarter FROM public.game_state WHERE id = 1), player_row.id)) WHERE value->>'playerId' = player_row.id::text),
      'topDogRank', (SELECT value->'rank' FROM jsonb_array_elements(public.kennel_ladder(NULL, player_row.id)) WHERE value->>'playerId' = player_row.id::text)
    ),
    'quarterLadder', public.kennel_ladder((SELECT quarter FROM public.game_state WHERE id = 1), player_row.id),
    'topDogLadder', public.kennel_ladder(NULL, player_row.id),
    'activeBet', (SELECT jsonb_build_object('id', b.id, 'marketId', b.market_id, 'optionId', b.option_id,
      'stake', b.stake, 'payout', b.payout, 'profit', b.profit, 'settledAt', b.settled_at)
      FROM public.bets b JOIN public.markets m ON m.id = b.market_id
      WHERE b.player_id = player_row.id AND m.type = 'next_goal' AND m.status IN ('draft','open','locked')),
    -- One position per Futures or Studs market, keyed by marketId.
    'positions', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'marketId', b.market_id,
      'optionId', b.option_id, 'stake', b.stake, 'payout', b.payout, 'profit', b.profit,
      'settledAt', b.settled_at)), '[]'::jsonb)
      FROM public.bets b JOIN public.markets m ON m.id = b.market_id
      WHERE b.player_id = player_row.id AND m.type <> 'next_goal'),
    'recentActivity', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind,
      'amount', l.amount, 'marketId', l.market_id, 'reversalOfId', l.reversal_of_id,
      'balanceAfter', l.balance_after, 'createdAt', l.created_at) ORDER BY l.sequence DESC), '[]'::jsonb)
      FROM (SELECT * FROM public.ledger WHERE player_id = player_row.id ORDER BY sequence DESC LIMIT 20) l),
    'ownedSquareIds', COALESCE((
      SELECT jsonb_agg(square.id ORDER BY square.id)
      FROM public.squares AS square
      JOIN public.squares_purchases AS purchase ON purchase.id = square.purchase_id
      WHERE purchase.linked_player_id = player_row.id
    ), '[]'::jsonb)
  );
END;
$$;

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
    -- Both Futures, including drafts the guests cannot see yet.
    'futures', COALESCE((
      SELECT jsonb_agg(public.kennel_market_snapshot(m.id) ORDER BY m.type DESC)
      FROM public.markets m WHERE m.type IN ('futures_winner', 'futures_norm_smith')
    ), '[]'::jsonb)
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- Join by picking your name from the squares board
-- ---------------------------------------------------------------------------
--
-- The club runs on an honesty code, so a guest claims a board name by choosing
-- it. A name can be claimed once; the host can relink from the console. A guest
-- not on the board picks a nickname, which may not impersonate a board name.
DROP FUNCTION public.kennel_join_player(text, text, text);
CREATE FUNCTION public.kennel_join_player(
  p_nickname text,
  p_claim_email text,
  p_token_hash text,
  p_purchase_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  player_row public.players%ROWTYPE;
  purchase public.squares_purchases%ROWTYPE;
  normalized_email text := NULLIF(lower(btrim(p_claim_email)), '');
  chosen_nickname text := btrim(COALESCE(p_nickname, ''));
BEGIN
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  IF length(p_token_hash) < 32 THEN
    RAISE EXCEPTION 'Invalid player session token';
  END IF;

  SELECT * INTO player_row FROM public.players WHERE session_token_hash = p_token_hash;
  IF FOUND THEN
    PERFORM public.kennel_apply_player_grants(player_row.id);
    RETURN public.kennel_player_snapshot(p_token_hash);
  END IF;

  IF p_purchase_id IS NOT NULL THEN
    SELECT * INTO purchase FROM public.squares_purchases WHERE id = p_purchase_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;
    IF purchase.linked_player_id IS NOT NULL THEN RAISE EXCEPTION 'That name has already been claimed'; END IF;
    chosen_nickname := left(btrim(purchase.purchaser_name), 24);
  ELSIF EXISTS (SELECT 1 FROM public.squares_purchases
    WHERE lower(btrim(purchaser_name)) = lower(chosen_nickname)) THEN
    RAISE EXCEPTION 'That name is on the squares board. Pick it from the list.';
  END IF;

  IF length(chosen_nickname) NOT BETWEEN 2 AND 24 THEN
    RAISE EXCEPTION 'Nickname must be between 2 and 24 characters';
  END IF;

  INSERT INTO public.players (nickname, session_token_hash, claim_email)
  VALUES (chosen_nickname, p_token_hash, normalized_email)
  RETURNING * INTO player_row;

  IF p_purchase_id IS NOT NULL THEN
    UPDATE public.squares_purchases SET linked_player_id = player_row.id WHERE id = p_purchase_id;
  ELSIF normalized_email IS NOT NULL THEN
    UPDATE public.squares_purchases
    SET linked_player_id = player_row.id
    WHERE lower(purchaser_email) = normalized_email
      AND linked_player_id IS NULL;
  END IF;

  PERFORM public.kennel_recalculate_player_squares();
  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  PERFORM public.kennel_emit_event('grid_updated', '{}'::jsonb);
  RETURN public.kennel_player_snapshot(p_token_hash);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'That nickname is already in the pack';
END;
$$;

-- ---------------------------------------------------------------------------
-- Athletes: entered by name, one identity per name
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.kennel_ensure_athletes(p_host_token_hash text, p_athletes jsonb, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cached jsonb; result jsonb; entry jsonb; athlete_name text; team text;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'ensure_athletes'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  IF jsonb_typeof(p_athletes) <> 'array' OR jsonb_array_length(p_athletes) = 0 THEN
    RAISE EXCEPTION 'An athlete name is required';
  END IF;

  FOR entry IN SELECT value FROM jsonb_array_elements(p_athletes) LOOP
    athlete_name := btrim(COALESCE(entry->>'name', ''));
    team := NULLIF(btrim(COALESCE(entry->>'team', '')), '');
    IF length(athlete_name) NOT BETWEEN 1 AND 80 OR length(COALESCE(team, 'x')) > 40 THEN
      RAISE EXCEPTION 'An athlete name is required';
    END IF;
    INSERT INTO public.athletes(display_name, team_label) VALUES(athlete_name, team)
      ON CONFLICT ((lower(btrim(display_name)))) DO UPDATE
      SET team_label = COALESCE(EXCLUDED.team_label, public.athletes.team_label);
  END LOOP;

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('ensure_athletes', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Configure a matchup, before it opens
-- ---------------------------------------------------------------------------
--
-- A null athlete A removes the matchup. Q1 baselines are zero; later quarters'
-- baselines are entered at the break with kennel_set_studs_baselines.
CREATE FUNCTION public.kennel_configure_studs_matchup(
  p_host_token_hash text, p_quarter integer, p_slot integer, p_round_label text, p_stat text,
  p_athlete_a_id uuid, p_athlete_b_id uuid, p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cached jsonb; result jsonb; existing public.studs_matchups%ROWTYPE;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'configure_studs_matchup'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  IF p_quarter IS NULL OR p_quarter NOT BETWEEN 1 AND 4 OR p_slot IS NULL OR p_slot NOT BETWEEN 1 AND 3 THEN
    RAISE EXCEPTION 'A matchup needs a quarter from 1 to 4 and a slot from 1 to 3';
  END IF;

  SELECT * INTO existing FROM public.studs_matchups WHERE quarter = p_quarter AND slot = p_slot FOR UPDATE;
  IF FOUND AND existing.market_id IS NOT NULL THEN
    RAISE EXCEPTION 'Studs matchups can only change before they open';
  END IF;

  IF p_athlete_a_id IS NULL THEN
    DELETE FROM public.studs_matchups WHERE quarter = p_quarter AND slot = p_slot;
  ELSE
    IF p_athlete_b_id IS NULL OR p_athlete_a_id = p_athlete_b_id THEN
      RAISE EXCEPTION 'Choose two different athletes';
    END IF;
    IF (SELECT count(*) FROM public.athletes WHERE id IN (p_athlete_a_id, p_athlete_b_id)) <> 2 THEN
      RAISE EXCEPTION 'Unknown athlete';
    END IF;
    IF p_stat IS NULL OR p_stat NOT IN ('disposals', 'hitouts') THEN
      RAISE EXCEPTION 'Choose disposals or hit-outs';
    END IF;
    IF p_round_label IS NULL OR length(btrim(p_round_label)) NOT BETWEEN 1 AND 40 THEN
      RAISE EXCEPTION 'A round label is required';
    END IF;
    INSERT INTO public.studs_matchups(quarter, slot, round_label, stat, athlete_a_id, athlete_b_id,
      baseline_a, baseline_b)
    VALUES(p_quarter, p_slot, btrim(p_round_label), p_stat, p_athlete_a_id, p_athlete_b_id,
      CASE WHEN p_quarter = 1 THEN 0 END, CASE WHEN p_quarter = 1 THEN 0 END)
    ON CONFLICT (quarter, slot) DO UPDATE SET round_label = EXCLUDED.round_label, stat = EXCLUDED.stat,
      athlete_a_id = EXCLUDED.athlete_a_id, athlete_b_id = EXCLUDED.athlete_b_id,
      baseline_a = EXCLUDED.baseline_a, baseline_b = EXCLUDED.baseline_b, updated_at = clock_timestamp();
  END IF;

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('configure_studs_matchup', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Open a quarter's matchups: pre-match for Q1, at the siren for the rest
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.kennel_open_studs_internal(p_quarter integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE s record; new_market uuid; opened integer := 0; opening timestamptz := clock_timestamp();
BEGIN
  FOR s IN SELECT sm.*, a.display_name AS a_name, b.display_name AS b_name
    FROM public.studs_matchups sm
    JOIN public.athletes a ON a.id = sm.athlete_a_id
    JOIN public.athletes b ON b.id = sm.athlete_b_id
    WHERE sm.quarter = p_quarter AND sm.market_id IS NULL
    ORDER BY sm.slot FOR UPDATE OF sm
  LOOP
    INSERT INTO public.markets(type, quarter, title, status, opens_at, locks_at, lock_strategy)
      VALUES('studs_v_spuds', p_quarter, s.a_name || ' v ' || s.b_name, 'open', opening, NULL, 'bounce')
      RETURNING id INTO new_market;
    INSERT INTO public.market_options(market_id, option_key, label, sort_order, athlete_id)
      VALUES(new_market, 'athlete_a', s.a_name, 0, s.athlete_a_id),
            (new_market, 'athlete_b', s.b_name, 1, s.athlete_b_id);
    UPDATE public.studs_matchups SET market_id = new_market, updated_at = clock_timestamp() WHERE id = s.id;
    PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', new_market, 'status', 'open'));
    opened := opened + 1;
  END LOOP;
  RETURN opened;
END;
$$;

CREATE FUNCTION public.kennel_open_studs(p_host_token_hash text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE g public.game_state%ROWTYPE; cached jsonb; result jsonb; upcoming integer;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO g FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'open_studs'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  IF g.period_status = 'pre_match' THEN upcoming := 1;
  ELSIF g.period_status = 'break' THEN upcoming := g.quarter + 1;
  ELSE RAISE EXCEPTION 'Studs matchups open during a break or before the first bounce';
  END IF;

  PERFORM public.kennel_open_studs_internal(upcoming);
  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('open_studs', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Baselines: the cumulative totals at the start of the quarter covered
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.kennel_set_studs_baselines(p_host_token_hash text, p_matchup_id uuid,
  p_baseline_a integer, p_baseline_b integer, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cached jsonb; result jsonb; s public.studs_matchups%ROWTYPE;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'set_studs_baselines'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  SELECT * INTO s FROM public.studs_matchups WHERE id = p_matchup_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Matchup not found'; END IF;
  IF s.resolved_at IS NOT NULL THEN RAISE EXCEPTION 'This matchup is already resolved'; END IF;
  IF s.quarter = 1 THEN RAISE EXCEPTION 'Q1 baselines are zero'; END IF;
  IF p_baseline_a IS NULL OR p_baseline_b IS NULL OR p_baseline_a < 0 OR p_baseline_b < 0 THEN
    RAISE EXCEPTION 'Totals must be whole numbers of zero or more';
  END IF;

  UPDATE public.studs_matchups SET baseline_a = p_baseline_a, baseline_b = p_baseline_b,
    updated_at = clock_timestamp() WHERE id = s.id;
  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('set_studs_baselines', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Resolve a matchup, and finalize its quarter's ladder once all are resolved
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.kennel_finalize_quarter_ladder(p_quarter integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.markets WHERE type = 'studs_v_spuds' AND quarter = p_quarter
    AND settled_at IS NULL) THEN
    RETURN;
  END IF;
  UPDATE public.quarter_results SET quarter_ladder = public.kennel_ladder(p_quarter),
    ladder_finalized_at = clock_timestamp()
  WHERE quarter = p_quarter AND ladder_finalized_at IS NULL;
  PERFORM public.kennel_emit_event('ladder_updated', '{}'::jsonb);
END;
$$;

-- The host enters cumulative game-to-date totals at the siren; the server
-- subtracts the stored baselines. Equal quarter totals void and refund.
CREATE FUNCTION public.kennel_settle_studs(p_host_token_hash text, p_matchup_id uuid,
  p_ending_a integer, p_ending_b integer, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cached jsonb; result jsonb; s public.studs_matchups%ROWTYPE; quarter_a integer; quarter_b integer;
  winning_option uuid;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'settle_studs'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;

  SELECT * INTO s FROM public.studs_matchups WHERE id = p_matchup_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Matchup not found'; END IF;
  IF s.market_id IS NULL THEN RAISE EXCEPTION 'This matchup never opened'; END IF;
  IF s.resolved_at IS NOT NULL THEN RAISE EXCEPTION 'This matchup is already resolved'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.quarter_results WHERE quarter = s.quarter) THEN
    RAISE EXCEPTION 'Settle this matchup after its quarter siren';
  END IF;
  IF s.baseline_a IS NULL OR s.baseline_b IS NULL THEN
    RAISE EXCEPTION 'Enter this matchup''s baselines first';
  END IF;
  IF p_ending_a IS NULL OR p_ending_b IS NULL OR p_ending_a < 0 OR p_ending_b < 0 THEN
    RAISE EXCEPTION 'Totals must be whole numbers of zero or more';
  END IF;
  IF p_ending_a < s.baseline_a OR p_ending_b < s.baseline_b THEN
    RAISE EXCEPTION 'A cumulative total cannot be lower than its baseline';
  END IF;

  quarter_a := p_ending_a - s.baseline_a;
  quarter_b := p_ending_b - s.baseline_b;
  UPDATE public.studs_matchups SET ending_a = p_ending_a, ending_b = p_ending_b,
    resolved_at = clock_timestamp(), updated_at = clock_timestamp() WHERE id = s.id;

  IF quarter_a = quarter_b THEN
    PERFORM public.kennel_finish_market(s.market_id, NULL, 'Level on the quarter', p_request_id);
  ELSE
    SELECT id INTO winning_option FROM public.market_options WHERE market_id = s.market_id
      AND option_key = CASE WHEN quarter_a > quarter_b THEN 'athlete_a' ELSE 'athlete_b' END;
    PERFORM public.kennel_finish_market(s.market_id, winning_option, NULL, p_request_id);
  END IF;
  PERFORM public.kennel_finalize_quarter_ladder(s.quarter);

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('settle_studs', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- The explicit escape hatch: a withdrawn player, or stats nobody can find.
CREATE FUNCTION public.kennel_void_studs(p_host_token_hash text, p_matchup_id uuid, p_reason text, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE cached jsonb; result jsonb; s public.studs_matchups%ROWTYPE;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'void_studs'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'A short void reason is required';
  END IF;

  SELECT * INTO s FROM public.studs_matchups WHERE id = p_matchup_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Matchup not found'; END IF;
  IF s.market_id IS NULL THEN RAISE EXCEPTION 'This matchup never opened'; END IF;
  IF s.resolved_at IS NOT NULL THEN RAISE EXCEPTION 'This matchup is already resolved'; END IF;

  UPDATE public.studs_matchups SET resolved_at = clock_timestamp(), updated_at = clock_timestamp() WHERE id = s.id;
  PERFORM public.kennel_finish_market(s.market_id, NULL, btrim(p_reason), p_request_id);
  PERFORM public.kennel_finalize_quarter_ladder(s.quarter);

  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('void_studs', p_request_id, p_host_token_hash, result);
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- The siren: seal Squares at once, hold the ladder for Studs, open the next break
-- ---------------------------------------------------------------------------
--
-- Unchanged from Phase 2 except for the ladder_finalized_at value and the
-- opening of the next quarter's matchups once play has stopped.
CREATE OR REPLACE FUNCTION public.kennel_end_quarter(
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
  grid public.grid_config%ROWTYPE;
  square_id integer;
  active_market_id uuid;
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO game FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'end_quarter' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF game.period_status <> 'live' THEN RAISE EXCEPTION 'No quarter is currently live'; END IF;

  SELECT id INTO active_market_id FROM public.markets WHERE type = 'next_goal' AND status IN ('draft','open','locked') FOR UPDATE;
  IF active_market_id IS NOT NULL THEN
    PERFORM public.kennel_finish_market(active_market_id, NULL, 'Quarter ended', p_request_id);
  END IF;

  SELECT * INTO grid FROM public.grid_config WHERE id = 1;
  square_id := (array_position(grid.row_digits, game.home_points % 10) - 1) * 10
    + array_position(grid.col_digits, game.away_points % 10);

  INSERT INTO public.quarter_results (quarter, home_points, away_points, winning_square_id, quarter_ladder,
    ladder_finalized_at)
  VALUES (game.quarter, game.home_points, game.away_points, square_id, public.kennel_ladder(game.quarter),
    CASE WHEN EXISTS (SELECT 1 FROM public.markets WHERE type = 'studs_v_spuds' AND quarter = game.quarter
      AND settled_at IS NULL) THEN NULL ELSE now() END)
  ON CONFLICT (quarter) DO NOTHING;

  UPDATE public.game_state SET
    period_status = CASE WHEN game.quarter = 4 THEN 'final' ELSE 'break' END,
    version = version + 1,
    updated_at = now()
  WHERE id = 1;

  IF game.quarter < 4 THEN
    PERFORM public.kennel_open_studs_internal(game.quarter + 1);
  END IF;

  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts VALUES (
    'end_quarter', p_request_id, p_host_token_hash, result, now()
  );
  PERFORM public.kennel_emit_event('quarter_updated', jsonb_build_object(
    'version', result #> '{game,version}', 'quarter', game.quarter,
    'status', CASE WHEN game.quarter = 4 THEN 'final' ELSE 'break' END,
    'winningSquareId', square_id
  ));
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Access boundary: the edge function is the only caller
-- ---------------------------------------------------------------------------
DO $grants$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'kennel_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.signature);
  END LOOP;
END
$grants$;

GRANT EXECUTE ON FUNCTION public.kennel_join_player(text, text, text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_ensure_athletes(text, jsonb, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_configure_studs_matchup(text, integer, integer, text, text, uuid, uuid, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_open_studs(text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_set_studs_baselines(text, uuid, integer, integer, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_settle_studs(text, uuid, integer, integer, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_void_studs(text, uuid, text, uuid) TO project_admin;
