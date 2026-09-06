CREATE OR REPLACE FUNCTION public.kennel_valid_digit_order(value integer[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT COALESCE(
    array_length(value, 1) = 10
    AND (SELECT count(DISTINCT digit) = 10 FROM unnest(value) AS digit)
    AND (SELECT min(digit) = 0 AND max(digit) = 9 FROM unnest(value) AS digit),
    false
  );
$$;

CREATE TABLE public.event_config (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  event_name text NOT NULL,
  event_code text NOT NULL,
  venue text NOT NULL,
  starts_at timestamptz NOT NULL,
  timezone text NOT NULL DEFAULT 'America/Denver',
  home_team text NOT NULL,
  away_team text NOT NULL,
  zeffy_url text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (length(btrim(event_name)) BETWEEN 1 AND 100),
  CHECK (length(btrim(event_code)) BETWEEN 2 AND 20),
  CHECK (length(btrim(home_team)) BETWEEN 1 AND 60),
  CHECK (length(btrim(away_team)) BETWEEN 1 AND 60)
);

CREATE TABLE public.grid_config (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  row_digits integer[] NOT NULL,
  col_digits integer[] NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT grid_config_valid_rows CHECK (public.kennel_valid_digit_order(row_digits)),
  CONSTRAINT grid_config_valid_cols CHECK (public.kennel_valid_digit_order(col_digits))
);

CREATE TABLE public.players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nickname text NOT NULL,
  session_token_hash text NOT NULL UNIQUE,
  claim_email text,
  balance integer NOT NULL DEFAULT 0 CHECK (balance >= 0),
  squares_count integer NOT NULL DEFAULT 0 CHECK (squares_count >= 0),
  is_square_holder boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (length(btrim(nickname)) BETWEEN 2 AND 24),
  CHECK (claim_email IS NULL OR length(claim_email) <= 320)
);

CREATE UNIQUE INDEX players_nickname_case_insensitive_idx
  ON public.players (lower(btrim(nickname)));
CREATE INDEX players_claim_email_idx
  ON public.players (lower(claim_email)) WHERE claim_email IS NOT NULL;

CREATE TABLE public.square_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checksum text NOT NULL UNIQUE,
  source_name text NOT NULL,
  imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.squares_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.square_import_batches(id) ON DELETE RESTRICT,
  source_ref text NOT NULL,
  purchaser_name text NOT NULL,
  purchaser_email text NOT NULL,
  squares_count integer NOT NULL CHECK (squares_count BETWEEN 1 AND 100),
  linked_player_id uuid REFERENCES public.players(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (batch_id, source_ref),
  CHECK (length(btrim(purchaser_name)) BETWEEN 1 AND 120),
  CHECK (length(purchaser_email) <= 320)
);

CREATE INDEX squares_purchases_email_idx ON public.squares_purchases (lower(purchaser_email));
CREATE INDEX squares_purchases_linked_player_idx ON public.squares_purchases (linked_player_id);

CREATE TABLE public.squares (
  id integer PRIMARY KEY CHECK (id BETWEEN 1 AND 100),
  row_index integer NOT NULL CHECK (row_index BETWEEN 0 AND 9),
  col_index integer NOT NULL CHECK (col_index BETWEEN 0 AND 9),
  purchase_id uuid REFERENCES public.squares_purchases(id) ON DELETE SET NULL,
  UNIQUE (row_index, col_index)
);

CREATE INDEX squares_purchase_idx ON public.squares (purchase_id);

CREATE TABLE public.game_state (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  quarter integer NOT NULL DEFAULT 1 CHECK (quarter BETWEEN 1 AND 4),
  period_status text NOT NULL DEFAULT 'pre_match'
    CHECK (period_status IN ('pre_match', 'live', 'break', 'final')),
  home_goals integer NOT NULL DEFAULT 0 CHECK (home_goals >= 0),
  home_behinds integer NOT NULL DEFAULT 0 CHECK (home_behinds >= 0),
  home_points integer NOT NULL DEFAULT 0 CHECK (home_points >= 0),
  away_goals integer NOT NULL DEFAULT 0 CHECK (away_goals >= 0),
  away_behinds integer NOT NULL DEFAULT 0 CHECK (away_behinds >= 0),
  away_points integer NOT NULL DEFAULT 0 CHECK (away_points >= 0),
  betting_paused boolean NOT NULL DEFAULT false,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  last_score_event_id uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (home_points = home_goals * 6 + home_behinds),
  CHECK (away_points = away_goals * 6 + away_behinds)
);

CREATE TABLE public.score_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  request_id uuid NOT NULL UNIQUE,
  quarter integer NOT NULL CHECK (quarter BETWEEN 1 AND 4),
  team text NOT NULL CHECK (team IN ('home', 'away')),
  score_type text NOT NULL CHECK (score_type IN ('goal', 'behind')),
  home_goals integer NOT NULL CHECK (home_goals >= 0),
  home_behinds integer NOT NULL CHECK (home_behinds >= 0),
  home_points integer NOT NULL CHECK (home_points >= 0),
  away_goals integer NOT NULL CHECK (away_goals >= 0),
  away_behinds integer NOT NULL CHECK (away_behinds >= 0),
  away_points integer NOT NULL CHECK (away_points >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  voided_at timestamptz,
  CHECK (home_points = home_goals * 6 + home_behinds),
  CHECK (away_points = away_goals * 6 + away_behinds)
);

CREATE INDEX score_events_active_sequence_idx
  ON public.score_events (sequence DESC) WHERE voided_at IS NULL;

ALTER TABLE public.game_state
  ADD CONSTRAINT game_state_last_score_event_fk
  FOREIGN KEY (last_score_event_id) REFERENCES public.score_events(id) ON DELETE SET NULL;

CREATE TABLE public.quarter_results (
  quarter integer PRIMARY KEY CHECK (quarter BETWEEN 1 AND 4),
  home_points integer NOT NULL CHECK (home_points >= 0),
  away_points integer NOT NULL CHECK (away_points >= 0),
  winning_square_id integer NOT NULL REFERENCES public.squares(id) ON DELETE RESTRICT,
  settled_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.host_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (expires_at > created_at)
);

CREATE INDEX host_sessions_active_token_idx
  ON public.host_sessions (token_hash, expires_at) WHERE revoked_at IS NULL;

CREATE TABLE public.mutation_receipts (
  action text NOT NULL,
  idempotency_key uuid NOT NULL,
  actor_fingerprint text NOT NULL,
  response jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (action, idempotency_key)
);

CREATE TABLE public.game_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  event_type text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX game_events_created_at_idx ON public.game_events (created_at DESC);

INSERT INTO public.event_config (
  id, event_name, event_code, venue, starts_at, timezone, home_team, away_team, zeffy_url
) VALUES (
  1,
  'Denver Bulldogs Grand Final Night',
  'DOGS26',
  '1111 Lincoln St, Denver CO',
  '2026-09-26T04:30:00Z',
  'America/Denver',
  'Home',
  'Away',
  NULL
);

INSERT INTO public.grid_config (id, row_digits, col_digits)
VALUES (1, ARRAY[7,2,9,4,0,6,1,8,3,5], ARRAY[3,8,1,6,0,5,9,2,7,4]);

INSERT INTO public.game_state (id) VALUES (1);

INSERT INTO public.squares (id, row_index, col_index)
SELECT value, (value - 1) / 10, (value - 1) % 10
FROM generate_series(1, 100) AS value;

CREATE OR REPLACE FUNCTION public.kennel_recalculate_player_squares()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  UPDATE public.players AS player
  SET squares_count = totals.squares_count,
      is_square_holder = totals.squares_count > 0,
      updated_at = now()
  FROM (
    SELECT p.id,
      COALESCE((
        SELECT sum(purchase.squares_count)::integer
        FROM public.squares_purchases AS purchase
        WHERE purchase.linked_player_id = p.id
      ), 0) AS squares_count
    FROM public.players AS p
  ) AS totals
  WHERE player.id = totals.id;
$$;

CREATE OR REPLACE FUNCTION public.kennel_public_snapshot()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'serverNow', now(),
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
        'settledAt', result.settled_at
      ) ORDER BY result.quarter)
      FROM public.quarter_results AS result
      JOIN public.squares AS square ON square.id = result.winning_square_id
      LEFT JOIN public.squares_purchases AS purchase ON purchase.id = square.purchase_id
      LEFT JOIN public.players AS player ON player.id = purchase.linked_player_id
    ), '[]'::jsonb)
  )
  FROM public.event_config AS event
  CROSS JOIN public.game_state AS game
  CROSS JOIN public.grid_config AS grid
  WHERE event.id = 1 AND game.id = 1 AND grid.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.kennel_player_snapshot(p_token_hash text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
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
      'isSquareHolder', player_row.is_square_holder
    ),
    'ownedSquareIds', COALESCE((
      SELECT jsonb_agg(square.id ORDER BY square.id)
      FROM public.squares AS square
      JOIN public.squares_purchases AS purchase ON purchase.id = square.purchase_id
      WHERE purchase.linked_player_id = player_row.id
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_join_player(
  p_nickname text,
  p_claim_email text,
  p_token_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  player_row public.players%ROWTYPE;
  normalized_email text := NULLIF(lower(btrim(p_claim_email)), '');
BEGIN
  IF length(btrim(p_nickname)) NOT BETWEEN 2 AND 24 THEN
    RAISE EXCEPTION 'Nickname must be between 2 and 24 characters';
  END IF;
  IF length(p_token_hash) < 32 THEN
    RAISE EXCEPTION 'Invalid player session token';
  END IF;

  SELECT * INTO player_row FROM public.players WHERE session_token_hash = p_token_hash;
  IF FOUND THEN
    RETURN public.kennel_player_snapshot(p_token_hash);
  END IF;

  INSERT INTO public.players (nickname, session_token_hash, claim_email)
  VALUES (btrim(p_nickname), p_token_hash, normalized_email)
  RETURNING * INTO player_row;

  IF normalized_email IS NOT NULL THEN
    UPDATE public.squares_purchases
    SET linked_player_id = player_row.id
    WHERE lower(purchaser_email) = normalized_email
      AND linked_player_id IS NULL;
  END IF;

  PERFORM public.kennel_recalculate_player_squares();
  RETURN public.kennel_player_snapshot(p_token_hash);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'That nickname is already in the pack';
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_require_host(p_token_hash text)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  session_id uuid;
BEGIN
  SELECT id INTO session_id
  FROM public.host_sessions
  WHERE token_hash = p_token_hash
    AND revoked_at IS NULL
    AND expires_at > now();

  IF session_id IS NULL THEN
    RAISE EXCEPTION 'Host session is no longer valid';
  END IF;
  RETURN session_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_host_snapshot(p_host_token_hash text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  RETURN public.kennel_public_snapshot() || jsonb_build_object(
    'players', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', player.id,
        'nickname', player.nickname,
        'squaresCount', player.squares_count,
        'isSquareHolder', player.is_square_holder
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
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_emit_event(p_event_type text, p_payload jsonb)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  INSERT INTO public.game_events (event_type, payload) VALUES (p_event_type, p_payload);
$$;

CREATE OR REPLACE FUNCTION public.kennel_record_score(
  p_host_token_hash text,
  p_team text,
  p_score_type text,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  game public.game_state%ROWTYPE;
  score_id uuid;
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO game FROM public.game_state WHERE id = 1 FOR UPDATE;

  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'record_score' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;

  IF game.period_status <> 'live' THEN
    RAISE EXCEPTION 'Start the quarter before entering a score';
  END IF;
  IF p_team NOT IN ('home', 'away') OR p_score_type NOT IN ('goal', 'behind') THEN
    RAISE EXCEPTION 'Invalid score action';
  END IF;

  IF p_team = 'home' THEN
    game.home_goals := game.home_goals + CASE WHEN p_score_type = 'goal' THEN 1 ELSE 0 END;
    game.home_behinds := game.home_behinds + CASE WHEN p_score_type = 'behind' THEN 1 ELSE 0 END;
    game.home_points := game.home_points + CASE WHEN p_score_type = 'goal' THEN 6 ELSE 1 END;
  ELSE
    game.away_goals := game.away_goals + CASE WHEN p_score_type = 'goal' THEN 1 ELSE 0 END;
    game.away_behinds := game.away_behinds + CASE WHEN p_score_type = 'behind' THEN 1 ELSE 0 END;
    game.away_points := game.away_points + CASE WHEN p_score_type = 'goal' THEN 6 ELSE 1 END;
  END IF;

  INSERT INTO public.score_events (
    request_id, quarter, team, score_type,
    home_goals, home_behinds, home_points,
    away_goals, away_behinds, away_points
  ) VALUES (
    p_request_id, game.quarter, p_team, p_score_type,
    game.home_goals, game.home_behinds, game.home_points,
    game.away_goals, game.away_behinds, game.away_points
  ) RETURNING id INTO score_id;

  UPDATE public.game_state SET
    home_goals = game.home_goals,
    home_behinds = game.home_behinds,
    home_points = game.home_points,
    away_goals = game.away_goals,
    away_behinds = game.away_behinds,
    away_points = game.away_points,
    last_score_event_id = score_id,
    version = version + 1,
    updated_at = now()
  WHERE id = 1;

  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts (action, idempotency_key, actor_fingerprint, response)
  VALUES ('record_score', p_request_id, p_host_token_hash, result);
  PERFORM public.kennel_emit_event('score_updated', jsonb_build_object(
    'version', result #> '{game,version}', 'scoreEventId', score_id
  ));
  RETURN result;
END;
$$;

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

CREATE OR REPLACE FUNCTION public.kennel_start_quarter(
  p_host_token_hash text,
  p_quarter integer,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  game public.game_state%ROWTYPE;
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO game FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'start_quarter' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;

  IF p_quarter NOT BETWEEN 1 AND 4 THEN RAISE EXCEPTION 'Invalid quarter'; END IF;
  IF game.period_status = 'final' THEN RAISE EXCEPTION 'The match is already final'; END IF;
  IF game.period_status = 'live' THEN RAISE EXCEPTION 'A quarter is already live'; END IF;
  IF game.period_status = 'pre_match' AND p_quarter <> 1 THEN RAISE EXCEPTION 'The match must start at Q1'; END IF;
  IF game.period_status = 'break' AND p_quarter <> game.quarter + 1 THEN
    RAISE EXCEPTION 'Start the next quarter in sequence';
  END IF;

  UPDATE public.game_state SET quarter = p_quarter, period_status = 'live',
    version = version + 1, updated_at = now() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts VALUES (
    'start_quarter', p_request_id, p_host_token_hash, result, now()
  );
  PERFORM public.kennel_emit_event('quarter_updated', jsonb_build_object(
    'version', result #> '{game,version}', 'quarter', p_quarter, 'status', 'live'
  ));
  RETURN result;
END;
$$;

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

  SELECT * INTO grid FROM public.grid_config WHERE id = 1;
  square_id := (array_position(grid.row_digits, game.home_points % 10) - 1) * 10
    + array_position(grid.col_digits, game.away_points % 10);

  INSERT INTO public.quarter_results (quarter, home_points, away_points, winning_square_id)
  VALUES (game.quarter, game.home_points, game.away_points, square_id)
  ON CONFLICT (quarter) DO NOTHING;

  UPDATE public.game_state SET
    period_status = CASE WHEN game.quarter = 4 THEN 'final' ELSE 'break' END,
    version = version + 1,
    updated_at = now()
  WHERE id = 1;

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

CREATE OR REPLACE FUNCTION public.kennel_set_pause(
  p_host_token_hash text,
  p_paused boolean,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'set_pause' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;

  UPDATE public.game_state SET betting_paused = p_paused,
    version = version + 1, updated_at = now() WHERE id = 1;
  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts VALUES ('set_pause', p_request_id, p_host_token_hash, result, now());
  PERFORM public.kennel_emit_event('pause_updated', jsonb_build_object(
    'version', result #> '{game,version}', 'paused', p_paused
  ));
  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_set_grid(
  p_host_token_hash text,
  p_home_team text,
  p_away_team text,
  p_row_digits integer[],
  p_col_digits integer[],
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  game public.game_state%ROWTYPE;
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  SELECT * INTO game FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'set_grid' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;

  IF game.home_points + game.away_points > 0 OR EXISTS (SELECT 1 FROM public.quarter_results) THEN
    RAISE EXCEPTION 'Team and digit setup locks after the first score';
  END IF;
  IF NOT public.kennel_valid_digit_order(p_row_digits)
    OR NOT public.kennel_valid_digit_order(p_col_digits) THEN
    RAISE EXCEPTION 'Each digit order must contain 0 through 9 exactly once';
  END IF;
  IF length(btrim(p_home_team)) NOT BETWEEN 1 AND 60
    OR length(btrim(p_away_team)) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Both team names are required';
  END IF;

  UPDATE public.event_config SET home_team = btrim(p_home_team), away_team = btrim(p_away_team),
    updated_at = now() WHERE id = 1;
  UPDATE public.grid_config SET row_digits = p_row_digits, col_digits = p_col_digits,
    updated_at = now() WHERE id = 1;
  UPDATE public.game_state SET version = version + 1, updated_at = now() WHERE id = 1;

  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts VALUES ('set_grid', p_request_id, p_host_token_hash, result, now());
  PERFORM public.kennel_emit_event('grid_updated', jsonb_build_object(
    'version', result #> '{game,version}'
  ));
  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_link_purchase(
  p_host_token_hash text,
  p_purchase_id uuid,
  p_player_id uuid,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  cached jsonb;
  result jsonb;
BEGIN
  PERFORM public.kennel_require_host(p_host_token_hash);
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT response INTO cached FROM public.mutation_receipts
  WHERE action = 'link_purchase' AND idempotency_key = p_request_id
    AND actor_fingerprint = p_host_token_hash;
  IF FOUND THEN RETURN cached; END IF;

  IF p_player_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.players WHERE id = p_player_id) THEN
    RAISE EXCEPTION 'Player not found';
  END IF;
  UPDATE public.squares_purchases SET linked_player_id = p_player_id WHERE id = p_purchase_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase not found'; END IF;
  PERFORM public.kennel_recalculate_player_squares();
  UPDATE public.game_state SET version = version + 1, updated_at = now() WHERE id = 1;

  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts VALUES ('link_purchase', p_request_id, p_host_token_hash, result, now());
  PERFORM public.kennel_emit_event('grid_updated', jsonb_build_object(
    'version', result #> '{game,version}'
  ));
  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_import_square_purchases(
  p_checksum text,
  p_source_name text,
  p_rows jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  batch_id uuid;
  row_data jsonb;
  new_purchase_id uuid;
  assigned_count integer;
  expected_count integer;
BEGIN
  SELECT id INTO batch_id FROM public.square_import_batches WHERE checksum = p_checksum;
  IF FOUND THEN
    RETURN jsonb_build_object('batchId', batch_id, 'alreadyImported', true);
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'Import must contain at least one purchase';
  END IF;

  INSERT INTO public.square_import_batches (checksum, source_name)
  VALUES (p_checksum, p_source_name) RETURNING id INTO batch_id;

  FOR row_data IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    expected_count := (row_data->>'squaresCount')::integer;
    IF expected_count <> jsonb_array_length(row_data->'squareIds') THEN
      RAISE EXCEPTION 'Assigned square count does not match purchase quantity';
    END IF;

    INSERT INTO public.squares_purchases (
      batch_id, source_ref, purchaser_name, purchaser_email, squares_count
    ) VALUES (
      batch_id,
      row_data->>'sourceRef',
      btrim(row_data->>'purchaserName'),
      lower(btrim(row_data->>'purchaserEmail')),
      expected_count
    ) RETURNING id INTO new_purchase_id;

    UPDATE public.squares SET purchase_id = new_purchase_id
    WHERE id IN (SELECT value::integer FROM jsonb_array_elements_text(row_data->'squareIds'))
      AND public.squares.purchase_id IS NULL;
    GET DIAGNOSTICS assigned_count = ROW_COUNT;
    IF assigned_count <> expected_count THEN
      RAISE EXCEPTION 'One or more assigned squares are unavailable';
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'batchId', batch_id,
    'alreadyImported', false,
    'purchaseCount', jsonb_array_length(p_rows)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_publish_game_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  PERFORM realtime.publish('game:live', NEW.event_type, NEW.payload);
  RETURN NEW;
END;
$$;

CREATE TRIGGER game_events_publish_realtime
AFTER INSERT ON public.game_events
FOR EACH ROW EXECUTE FUNCTION public.kennel_publish_game_event();

INSERT INTO realtime.channels (pattern, description, enabled)
VALUES ('game:%', 'Read-only public updates for The Kennel', true)
ON CONFLICT (pattern) DO UPDATE SET description = EXCLUDED.description, enabled = true;

ALTER TABLE realtime.channels ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS kennel_public_game_subscribe ON realtime.channels;
CREATE POLICY kennel_public_game_subscribe
ON realtime.channels FOR SELECT TO anon, authenticated
USING (pattern = 'game:%' AND realtime.channel_name() = 'game:live');

GRANT USAGE ON SCHEMA realtime TO anon, authenticated;
GRANT SELECT ON realtime.channels TO anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON realtime.channels FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, SELECT ON realtime.messages FROM anon, authenticated;

ALTER TABLE public.event_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.grid_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.square_import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.squares_purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.squares ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.score_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quarter_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.host_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mutation_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.event_config, public.grid_config, public.players,
  public.square_import_batches, public.squares_purchases, public.squares,
  public.game_state, public.score_events, public.quarter_results,
  public.host_sessions, public.mutation_receipts, public.game_events
FROM anon, authenticated;

REVOKE ALL ON FUNCTION public.kennel_valid_digit_order(integer[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_recalculate_player_squares() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_public_snapshot() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_player_snapshot(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_join_player(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_require_host(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_host_snapshot(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_emit_event(text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_record_score(text, text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_undo_latest_score(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_start_quarter(text, integer, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_end_quarter(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_set_pause(text, boolean, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_set_grid(text, text, text, integer[], integer[], uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_link_purchase(text, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_import_square_purchases(text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.kennel_publish_game_event() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.kennel_public_snapshot() TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_player_snapshot(text) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_join_player(text, text, text) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_host_snapshot(text) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_record_score(text, text, text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_undo_latest_score(text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_start_quarter(text, integer, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_end_quarter(text, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_set_pause(text, boolean, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_set_grid(text, text, text, integer[], integer[], uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_link_purchase(text, uuid, uuid, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_import_square_purchases(text, text, jsonb) TO project_admin;
