-- All event mutations acquire game_state(1) first, then market/player rows.
-- A shared lock order prevents betting, grants, host scoring and undo deadlocks.
-- There is one event and at most 80 guests; correctness precedes parallel writes.
ALTER TABLE public.players
  ADD COLUMN courtesy_granted_at timestamptz,
  ADD COLUMN bonus_squares_granted integer NOT NULL DEFAULT 0 CHECK (bonus_squares_granted BETWEEN 0 AND 5);

CREATE TABLE public.markets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  type text NOT NULL CHECK (type IN ('next_goal','studs_v_spuds','futures_winner','futures_norm_smith')),
  quarter integer CHECK (quarter BETWEEN 1 AND 4),
  title text NOT NULL,
  status text NOT NULL CHECK (status IN ('draft','open','locked','settled','void')),
  opens_at timestamptz,
  locks_at timestamptz,
  settled_at timestamptz,
  winning_option_id uuid,
  max_stake integer CHECK (max_stake > 0),
  counts_toward_quarter_prize boolean NOT NULL DEFAULT true,
  sponsor_label text,
  void_reason text,
  settlement_winning_pool_bones integer CHECK (settlement_winning_pool_bones >= 0),
  settlement_losing_pool_bones integer CHECK (settlement_losing_pool_bones >= 0),
  settlement_dust_bones integer CHECK (settlement_dust_bones >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'open' OR (opens_at IS NOT NULL AND locks_at IS NOT NULL AND locks_at > opens_at)),
  CHECK (
    (status = 'settled' AND settled_at IS NOT NULL AND winning_option_id IS NOT NULL)
    OR (status = 'void' AND settled_at IS NOT NULL AND winning_option_id IS NULL)
    OR (status IN ('draft','open','locked') AND settled_at IS NULL AND winning_option_id IS NULL)
  ),
  CHECK (
    (settled_at IS NULL AND settlement_winning_pool_bones IS NULL AND settlement_losing_pool_bones IS NULL AND settlement_dust_bones IS NULL)
    OR (settled_at IS NOT NULL AND settlement_winning_pool_bones IS NOT NULL AND settlement_losing_pool_bones IS NOT NULL AND settlement_dust_bones IS NOT NULL)
  )
);
CREATE UNIQUE INDEX markets_one_active_next_goal_idx ON public.markets (type)
  WHERE type = 'next_goal' AND status IN ('draft','open','locked');
CREATE INDEX markets_status_type_sequence_idx ON public.markets(status, type, sequence DESC);
CREATE INDEX markets_quarter_settled_idx ON public.markets(quarter, settled_at);

CREATE TABLE public.market_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id uuid NOT NULL REFERENCES public.markets(id),
  option_key text NOT NULL,
  label text NOT NULL,
  pool_bones integer NOT NULL DEFAULT 0 CHECK (pool_bones >= 0),
  sort_order integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(market_id, option_key),
  UNIQUE(market_id, id)
);
CREATE INDEX market_options_market_sort_idx ON public.market_options(market_id, sort_order);
ALTER TABLE public.markets ADD CONSTRAINT markets_winner_fk
  FOREIGN KEY(id, winning_option_id) REFERENCES public.market_options(market_id, id);
CREATE INDEX markets_winner_idx ON public.markets(winning_option_id);

CREATE TABLE public.bets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id uuid NOT NULL REFERENCES public.markets(id),
  option_id uuid NOT NULL,
  player_id uuid NOT NULL REFERENCES public.players(id),
  stake integer NOT NULL CHECK (stake > 0),
  payout integer CHECK (payout >= 0),
  profit integer,
  settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(market_id, player_id),
  FOREIGN KEY(market_id, option_id) REFERENCES public.market_options(market_id, id),
  CHECK ((settled_at IS NULL AND payout IS NULL AND profit IS NULL)
    OR (settled_at IS NOT NULL AND payout IS NOT NULL AND profit IS NOT NULL AND profit = payout - stake))
);
CREATE INDEX bets_market_option_idx ON public.bets(market_id, option_id);
CREATE INDEX bets_player_settled_idx ON public.bets(player_id, settled_at DESC);

CREATE TABLE public.ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
  player_id uuid NOT NULL REFERENCES public.players(id),
  kind text NOT NULL CHECK (kind IN ('courtesy_grant','square_bonus','stake','payout','refund','bark')),
  amount integer NOT NULL CHECK (amount <> 0),
  market_id uuid REFERENCES public.markets(id),
  request_id uuid,
  reversal_of_id uuid UNIQUE REFERENCES public.ledger(id),
  balance_after integer NOT NULL CHECK (balance_after >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_player_created_idx ON public.ledger(player_id, created_at DESC, sequence DESC);
CREATE INDEX ledger_market_created_idx ON public.ledger(market_id, created_at) WHERE market_id IS NOT NULL;
ALTER TABLE public.score_events
  ADD COLUMN settled_market_id uuid REFERENCES public.markets(id),
  ADD COLUMN opened_market_id uuid REFERENCES public.markets(id);
CREATE INDEX score_events_settled_market_idx ON public.score_events(settled_market_id);
CREATE INDEX score_events_opened_market_idx ON public.score_events(opened_market_id);
ALTER TABLE public.quarter_results ADD COLUMN quarter_ladder jsonb NOT NULL DEFAULT '[]'::jsonb;
-- Receipt keys are scoped to their actor so unrelated guests cannot collide.
ALTER TABLE public.mutation_receipts DROP CONSTRAINT mutation_receipts_pkey;
ALTER TABLE public.mutation_receipts ADD PRIMARY KEY(action, idempotency_key, actor_fingerprint);

CREATE FUNCTION public.kennel_guard_ledger() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE original public.ledger%ROWTYPE;
BEGIN
  IF TG_OP <> 'INSERT' THEN RAISE EXCEPTION 'Bones activity is append-only'; END IF;
  IF NEW.reversal_of_id IS NOT NULL THEN
    SELECT * INTO original FROM public.ledger WHERE id = NEW.reversal_of_id;
    IF NOT FOUND OR original.reversal_of_id IS NOT NULL OR original.player_id <> NEW.player_id
      OR original.kind <> NEW.kind OR original.amount::bigint <> -NEW.amount::bigint
      OR original.market_id IS DISTINCT FROM NEW.market_id THEN
      RAISE EXCEPTION 'Invalid Bones reversal';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER ledger_immutable BEFORE INSERT OR UPDATE OR DELETE ON public.ledger
FOR EACH ROW EXECUTE FUNCTION public.kennel_guard_ledger();

CREATE FUNCTION public.kennel_write_ledger(
  p_player_id uuid, p_kind text, p_amount integer, p_market_id uuid DEFAULT NULL,
  p_request_id uuid DEFAULT NULL, p_reversal_of_id uuid DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE new_balance integer;
BEGIN
  IF p_amount = 0 THEN RETURN; END IF;
  UPDATE public.players SET balance = balance + p_amount, updated_at = clock_timestamp()
    WHERE id = p_player_id RETURNING balance INTO new_balance;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player session is no longer valid'; END IF;
  INSERT INTO public.ledger(player_id, kind, amount, market_id, request_id, reversal_of_id, balance_after)
    VALUES(p_player_id, p_kind, p_amount, p_market_id, p_request_id, p_reversal_of_id, new_balance);
END;
$$;

CREATE FUNCTION public.kennel_apply_player_grants(p_player_id uuid) RETURNS void LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE p public.players%ROWTYPE; eligible integer;
BEGIN
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT * INTO p FROM public.players WHERE id = p_player_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player session is no longer valid'; END IF;
  IF p.courtesy_granted_at IS NULL THEN
    PERFORM public.kennel_write_ledger(p.id, 'courtesy_grant', 1000);
    UPDATE public.players SET courtesy_granted_at = clock_timestamp() WHERE id = p.id;
  END IF;
  eligible := LEAST(p.squares_count, 5);
  IF eligible > p.bonus_squares_granted THEN
    PERFORM public.kennel_write_ledger(p.id, 'square_bonus', (eligible - p.bonus_squares_granted) * 250);
    UPDATE public.players SET bonus_squares_granted = eligible WHERE id = p.id;
  END IF;
END;
$$;

CREATE FUNCTION public.kennel_ladder(p_quarter integer DEFAULT NULL, p_player_id uuid DEFAULT NULL, p_limit integer DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('rank', rank, 'playerId', id, 'nickname', nickname,
    'profit', profit, 'isMe', COALESCE(id = p_player_id, false)) ORDER BY rank), '[]'::jsonb)
  FROM (
    SELECT row_number() OVER (ORDER BY profit DESC, lower(nickname), id) AS rank, *
    FROM (
      SELECT p.id, p.nickname, COALESCE(sum(b.profit) FILTER (
        WHERE m.status IN ('settled','void') AND (p_quarter IS NULL OR
          (m.quarter = p_quarter AND m.counts_toward_quarter_prize))
      ), 0) AS profit
      FROM public.players p LEFT JOIN public.bets b ON b.player_id = p.id
      LEFT JOIN public.markets m ON m.id = b.market_id GROUP BY p.id
    ) totals
  ) ranked WHERE p_limit IS NULL OR rank <= p_limit;
$$;

CREATE FUNCTION public.kennel_market_snapshot(p_market_id uuid) RETURNS jsonb LANGUAGE sql VOLATILE
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT jsonb_build_object(
    'id', m.id, 'sequence', m.sequence, 'type', m.type, 'quarter', m.quarter, 'title', m.title,
    'status', CASE WHEN m.status = 'open' AND clock_timestamp() >= m.locks_at THEN 'locked' ELSE m.status END,
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
      'betCount', (SELECT count(*) FROM public.bets WHERE option_id = o.id AND market_id = m.id)
    ) ORDER BY o.sort_order) FROM public.market_options o WHERE o.market_id = m.id)
  ) FROM public.markets m WHERE m.id = p_market_id;
$$;

CREATE FUNCTION public.kennel_emit_market_changes(p_market_id uuid) RETURNS void LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', p_market_id));
  PERFORM public.kennel_emit_event('bet_updated', jsonb_build_object('marketId', p_market_id));
  PERFORM public.kennel_emit_event('balance_updated', '{}'::jsonb);
  PERFORM public.kennel_emit_event('ladder_updated', '{}'::jsonb);
END;
$$;

CREATE FUNCTION public.kennel_open_next_goal_internal(p_lock_seconds integer DEFAULT 90) RETURNS uuid LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE g public.game_state%ROWTYPE; e public.event_config%ROWTYPE; market_id uuid; opening timestamptz;
BEGIN
  SELECT * INTO g FROM public.game_state WHERE id = 1 FOR UPDATE;
  IF g.period_status <> 'live' THEN RAISE EXCEPTION 'Start a quarter before opening a market'; END IF;
  IF p_lock_seconds IS NULL OR p_lock_seconds NOT BETWEEN 1 AND 300 THEN RAISE EXCEPTION 'Lock window must be between 1 and 300 seconds'; END IF;
  SELECT id INTO market_id FROM public.markets WHERE type = 'next_goal' AND status IN ('draft','open','locked') FOR UPDATE;
  IF FOUND THEN RETURN market_id; END IF;
  SELECT * INTO e FROM public.event_config WHERE id = 1;
  opening := clock_timestamp();
  INSERT INTO public.markets(type, quarter, title, status, opens_at, locks_at)
    VALUES('next_goal', g.quarter, 'Which team scores the next goal?', 'open', opening,
      opening + make_interval(secs => p_lock_seconds)) RETURNING id INTO market_id;
  INSERT INTO public.market_options(market_id, option_key, label, sort_order)
    VALUES(market_id, 'home', e.home_team, 0), (market_id, 'away', e.away_team, 1);
  PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', market_id, 'status', 'open'));
  RETURN market_id;
END;
$$;

CREATE FUNCTION public.kennel_finish_market(p_market_id uuid, p_winning_option_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL, p_request_id uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE m public.markets%ROWTYPE; b public.bets%ROWTYPE; winning bigint; losing bigint;
  paid_profit bigint := 0; credit integer; is_void boolean; finished timestamptz;
BEGIN
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT * INTO m FROM public.markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Market not found'; END IF;
  IF m.settled_at IS NOT NULL THEN RETURN; END IF;
  IF p_winning_option_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.market_options WHERE market_id = m.id AND id = p_winning_option_id
  ) THEN RAISE EXCEPTION 'Choose a team from this market'; END IF;
  PERFORM 1 FROM public.market_options WHERE market_id = m.id ORDER BY sort_order FOR UPDATE;
  IF m.status IN ('draft','open') THEN
    UPDATE public.markets SET status = 'locked', updated_at = clock_timestamp() WHERE id = m.id;
    PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', m.id, 'status', 'locked'));
  END IF;
  SELECT COALESCE(sum(stake) FILTER (WHERE option_id = p_winning_option_id), 0),
    COALESCE(sum(stake) FILTER (WHERE p_winning_option_id IS NULL OR option_id <> p_winning_option_id), 0)
    INTO winning, losing FROM public.bets WHERE market_id = m.id;
  is_void := p_winning_option_id IS NULL OR winning = 0;
  finished := clock_timestamp();
  FOR b IN SELECT * FROM public.bets WHERE market_id = m.id ORDER BY player_id FOR UPDATE LOOP
    credit := CASE WHEN is_void THEN b.stake WHEN b.option_id = p_winning_option_id
      THEN (b.stake::bigint + b.stake::bigint * losing / winning)::integer ELSE 0 END;
    IF NOT is_void AND b.option_id = p_winning_option_id THEN paid_profit := paid_profit + credit - b.stake; END IF;
    PERFORM public.kennel_write_ledger(b.player_id, CASE WHEN is_void THEN 'refund' ELSE 'payout' END,
      credit, m.id, p_request_id);
    UPDATE public.bets SET payout = credit, profit = credit - stake, settled_at = finished, updated_at = finished WHERE id = b.id;
  END LOOP;
  UPDATE public.markets SET status = CASE WHEN is_void THEN 'void' ELSE 'settled' END,
    settled_at = finished, winning_option_id = CASE WHEN is_void THEN NULL ELSE p_winning_option_id END,
    void_reason = CASE WHEN is_void THEN COALESCE(p_reason, 'No backers on the scoring team') ELSE NULL END,
    settlement_winning_pool_bones = winning, settlement_losing_pool_bones = losing,
    settlement_dust_bones = CASE WHEN is_void THEN 0 ELSE losing - paid_profit END, updated_at = finished WHERE id = m.id;
  PERFORM public.kennel_emit_market_changes(m.id);
END;
$$;

CREATE FUNCTION public.kennel_place_bet(p_token_hash text, p_market_id uuid, p_option_id uuid,
  p_stake_delta integer, p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE p public.players%ROWTYPE; m public.markets%ROWTYPE; b public.bets%ROWTYPE;
  paused boolean; cached jsonb; result jsonb;
BEGIN
  SELECT betting_paused INTO paused FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT * INTO p FROM public.players WHERE session_token_hash = p_token_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player session is no longer valid'; END IF;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'place_bet'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  SELECT * INTO m FROM public.markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Market not found'; END IF;
  IF m.status IN ('settled','void') THEN RAISE EXCEPTION 'Market is already settled or void'; END IF;
  IF m.status <> 'open' OR clock_timestamp() >= m.locks_at THEN RAISE EXCEPTION 'Market has locked'; END IF;
  IF paused THEN RAISE EXCEPTION 'Betting is paused'; END IF;
  IF p_stake_delta IS NULL OR p_stake_delta <= 0 THEN RAISE EXCEPTION 'Stake must be positive'; END IF;
  PERFORM 1 FROM public.market_options WHERE market_id = m.id AND id = p_option_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Choose a team from this market'; END IF;
  SELECT * INTO b FROM public.bets WHERE market_id = m.id AND player_id = p.id FOR UPDATE;
  IF FOUND AND b.option_id <> p_option_id THEN RAISE EXCEPTION 'Existing selection cannot be changed'; END IF;
  IF m.max_stake IS NOT NULL AND COALESCE(b.stake, 0)::bigint + p_stake_delta > m.max_stake THEN
    RAISE EXCEPTION 'Market cap reached';
  END IF;
  IF p.balance < p_stake_delta THEN RAISE EXCEPTION 'Not enough Bones'; END IF;
  INSERT INTO public.bets(market_id, option_id, player_id, stake) VALUES(m.id, p_option_id, p.id, p_stake_delta)
    ON CONFLICT(market_id, player_id) DO UPDATE SET stake = public.bets.stake + EXCLUDED.stake, updated_at = clock_timestamp();
  UPDATE public.market_options SET pool_bones = pool_bones + p_stake_delta WHERE market_id = m.id AND id = p_option_id;
  PERFORM public.kennel_write_ledger(p.id, 'stake', -p_stake_delta, m.id, p_request_id);
  UPDATE public.game_state SET version = version + 1, updated_at = clock_timestamp() WHERE id = 1;
  result := public.kennel_player_snapshot(p_token_hash);
  INSERT INTO public.mutation_receipts(action, idempotency_key, actor_fingerprint, response)
    VALUES('place_bet', p_request_id, p_token_hash, result);
  PERFORM public.kennel_emit_event('market_updated', jsonb_build_object('marketId', m.id));
  PERFORM public.kennel_emit_event('bet_updated', jsonb_build_object('marketId', m.id));
  PERFORM public.kennel_emit_event('balance_updated', '{}'::jsonb);
  RETURN result;
END;
$$;

CREATE FUNCTION public.kennel_market_action(p_host_token_hash text, p_action text, p_request_id uuid,
  p_market_id uuid DEFAULT NULL, p_winning_option_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL, p_lock_seconds integer DEFAULT 90) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
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


-- Extend snapshots and existing guest grant hooks.
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
        'quarterLadder', result.quarter_ladder
      ) ORDER BY result.quarter)
      FROM public.quarter_results AS result
      JOIN public.squares AS square ON square.id = result.winning_square_id
      LEFT JOIN public.squares_purchases AS purchase ON purchase.id = square.purchase_id
      LEFT JOIN public.players AS player ON player.id = purchase.linked_player_id
    ), '[]'::jsonb)
  ) || jsonb_build_object(
    'activeMarket', public.kennel_market_snapshot((SELECT id FROM public.markets WHERE type = 'next_goal' AND status IN ('draft','open','locked'))),
    'recentMarket', public.kennel_market_snapshot((SELECT id FROM public.markets WHERE settled_at IS NOT NULL ORDER BY sequence DESC LIMIT 1)),
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
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.kennel_recalculate_player_squares()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE player_id uuid;
BEGIN
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
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
  FOR player_id IN SELECT id FROM public.players ORDER BY id LOOP
    PERFORM public.kennel_apply_player_grants(player_id);
  END LOOP;
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
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  IF length(btrim(p_nickname)) NOT BETWEEN 2 AND 24 THEN
    RAISE EXCEPTION 'Nickname must be between 2 and 24 characters';
  END IF;
  IF length(p_token_hash) < 32 THEN
    RAISE EXCEPTION 'Invalid player session token';
  END IF;

  SELECT * INTO player_row FROM public.players WHERE session_token_hash = p_token_hash;
  IF FOUND THEN
    PERFORM public.kennel_apply_player_grants(player_row.id);
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

-- Only an audited reversal may clear an existing settlement. Ordinary retries
-- cannot modify its winner, pools, timestamp, reason or dust.
CREATE FUNCTION public.kennel_guard_market_audit() RETURNS trigger LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF OLD.settled_at IS NOT NULL AND
    ROW(NEW.status, NEW.settled_at, NEW.winning_option_id, NEW.void_reason,
      NEW.settlement_winning_pool_bones, NEW.settlement_losing_pool_bones, NEW.settlement_dust_bones)
    IS DISTINCT FROM ROW(OLD.status, OLD.settled_at, OLD.winning_option_id, OLD.void_reason,
      OLD.settlement_winning_pool_bones, OLD.settlement_losing_pool_bones, OLD.settlement_dust_bones) THEN
    IF NEW.settled_at IS NOT NULL OR EXISTS (
      SELECT 1 FROM public.ledger l WHERE l.market_id = OLD.id AND l.kind IN ('payout','refund')
      AND l.reversal_of_id IS NULL AND NOT EXISTS (SELECT 1 FROM public.ledger r WHERE r.reversal_of_id = l.id)
    ) OR EXISTS (SELECT 1 FROM public.bets WHERE market_id = OLD.id AND settled_at IS NOT NULL) THEN
      RAISE EXCEPTION 'Settlement audit is immutable until its credits are reversed';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER markets_settlement_audit BEFORE UPDATE ON public.markets
FOR EACH ROW EXECUTE FUNCTION public.kennel_guard_market_audit();

CREATE FUNCTION public.kennel_reverse_market_settlement(p_market_id uuid, p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE m public.markets%ROWTYPE; entry public.ledger%ROWTYPE;
BEGIN
  PERFORM 1 FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT * INTO m FROM public.markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND OR m.settled_at IS NULL THEN RETURN; END IF;
  FOR entry IN SELECT l.* FROM public.ledger l
    WHERE l.market_id = m.id AND l.kind IN ('payout','refund') AND l.reversal_of_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.ledger r WHERE r.reversal_of_id = l.id)
    ORDER BY l.player_id, l.sequence FOR UPDATE LOOP
    PERFORM public.kennel_write_ledger(entry.player_id, entry.kind, -entry.amount, m.id, p_request_id, entry.id);
  END LOOP;
  UPDATE public.bets SET payout = NULL, profit = NULL, settled_at = NULL, updated_at = clock_timestamp() WHERE market_id = m.id;
  UPDATE public.markets SET status = CASE WHEN clock_timestamp() < locks_at THEN 'open' ELSE 'locked' END,
    settled_at = NULL, winning_option_id = NULL, void_reason = NULL,
    settlement_winning_pool_bones = NULL, settlement_losing_pool_bones = NULL, settlement_dust_bones = NULL,
    updated_at = clock_timestamp() WHERE id = m.id;
  PERFORM public.kennel_emit_market_changes(m.id);
END;
$$;


-- Goal cycle and quarter integration, preserving Phase 1 score rules.
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
  prior_market_id uuid;
  next_market_id uuid;
  option_id uuid;
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

  IF p_score_type = 'goal' THEN
    SELECT id INTO prior_market_id FROM public.markets
      WHERE type = 'next_goal' AND status IN ('draft','open','locked') FOR UPDATE;
    IF prior_market_id IS NOT NULL THEN
      SELECT id INTO option_id FROM public.market_options WHERE market_id = prior_market_id AND option_key = p_team;
      PERFORM public.kennel_finish_market(prior_market_id, option_id, NULL, p_request_id);
    ELSE
      PERFORM public.kennel_emit_event('market_recovered', jsonb_build_object('scoreEventId', score_id,
        'reason', 'No active Next Goal market at goal entry'));
    END IF;
    next_market_id := public.kennel_open_next_goal_internal();
    UPDATE public.score_events SET settled_market_id = prior_market_id, opened_market_id = next_market_id WHERE id = score_id;
  END IF;

  result := public.kennel_host_snapshot(p_host_token_hash);
  INSERT INTO public.mutation_receipts (action, idempotency_key, actor_fingerprint, response)
  VALUES ('record_score', p_request_id, p_host_token_hash, result);
  PERFORM public.kennel_emit_event('score_updated', jsonb_build_object(
    'version', result #> '{game,version}', 'scoreEventId', score_id
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
  PERFORM public.kennel_open_next_goal_internal();
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

  INSERT INTO public.quarter_results (quarter, home_points, away_points, winning_square_id, quarter_ladder)
  VALUES (game.quarter, game.home_points, game.away_points, square_id, public.kennel_ladder(game.quarter))
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

  IF latest.opened_market_id IS NOT NULL THEN
    PERFORM public.kennel_finish_market(latest.opened_market_id, NULL, 'Goal undone', p_request_id);
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

-- Phase 1 never issued Bones. Refuse an unexplained opening balance instead of
-- inventing ledger history. All existing grant recipients backfill atomically.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM public.players WHERE balance <> 0) THEN
    RAISE EXCEPTION 'Reconcile existing Bones balances before applying Phase 2';
  END IF;
  PERFORM public.kennel_recalculate_player_squares();
END $$;

ALTER TABLE public.markets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.market_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "client access denied" ON public.markets FOR ALL TO anon, authenticated USING(false) WITH CHECK(false);
CREATE POLICY "client access denied" ON public.market_options FOR ALL TO anon, authenticated USING(false) WITH CHECK(false);
CREATE POLICY "client access denied" ON public.bets FOR ALL TO anon, authenticated USING(false) WITH CHECK(false);
CREATE POLICY "client access denied" ON public.ledger FOR ALL TO anon, authenticated USING(false) WITH CHECK(false);
REVOKE ALL ON public.markets, public.market_options, public.bets, public.ledger FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.markets_sequence_seq, public.ledger_sequence_seq FROM PUBLIC, anon, authenticated;

-- New helpers and replaced entry points keep the same server-only boundary.
DO $$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'kennel_%' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.signature);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION public.kennel_place_bet(text, uuid, uuid, integer, uuid) TO project_admin;
GRANT EXECUTE ON FUNCTION public.kennel_market_action(text, text, uuid, uuid, uuid, text, integer) TO project_admin;
