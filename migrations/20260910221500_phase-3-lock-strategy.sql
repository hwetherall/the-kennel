-- Phase 3, step 1: bounce locking and the live-play market invariant.
--
-- Enforces, in the database rather than by convention:
--   No market other than Next Goal is ever `open` while period_status = 'live'.
--
-- Next Goal keeps its 90-second deadline. Studs v Spuds and both Futures lock at
-- the opening bounce and carry no locks_at, instead of an invented far-future one.
-- See phase-3-undo-decision.md: this invariant is what makes phase-3.md section 4
-- unreachable, so no cross-market undo policy is needed.

ALTER TABLE public.markets
  ADD COLUMN lock_strategy text NOT NULL DEFAULT 'deadline'
    CHECK (lock_strategy IN ('deadline','bounce'));

-- Next Goal is the only in-play market, and so the only deadline-locked one.
ALTER TABLE public.markets ADD CONSTRAINT markets_lock_strategy_matches_type CHECK (
  (type = 'next_goal' AND lock_strategy = 'deadline')
  OR (type <> 'next_goal' AND lock_strategy = 'bounce')
);

-- The open-window CHECK was written inline, so it carries a generated name.
-- Find it by definition rather than guessing, and fail loudly if it has moved.
DO $migration$
DECLARE target text;
BEGIN
  -- STRICT: fail loudly on zero or on more than one match, rather than dropping
  -- an arbitrary constraint if the schema ever grows a second similar CHECK.
  SELECT c.conname INTO STRICT target
  FROM pg_constraint c
  WHERE c.conrelid = 'public.markets'::regclass
    AND c.contype = 'c'
    AND pg_get_constraintdef(c.oid) LIKE '%locks_at > opens_at%';
  EXECUTE format('ALTER TABLE public.markets DROP CONSTRAINT %I', target);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    RAISE EXCEPTION 'Could not find the markets open-window CHECK to replace';
  WHEN TOO_MANY_ROWS THEN
    RAISE EXCEPTION 'Several markets CHECKs mention locks_at > opens_at; resolve by hand';
END
$migration$;

-- A deadline market needs its clock; a bounce market must not carry one.
ALTER TABLE public.markets ADD CONSTRAINT markets_open_window CHECK (
  status <> 'open'
  OR (
    opens_at IS NOT NULL
    AND (
      (lock_strategy = 'deadline' AND locks_at IS NOT NULL AND locks_at > opens_at)
      OR (lock_strategy = 'bounce' AND locks_at IS NULL)
    )
  )
);

CREATE INDEX markets_open_bounce_idx ON public.markets(lock_strategy)
  WHERE status = 'open' AND lock_strategy = 'bounce';

-- Guard one: a bounce-locked market cannot become or stay open during live play.
-- This catches a host mis-tap and any direct SQL, not only the RPC path.
CREATE FUNCTION public.kennel_guard_market_bounce_lock() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NEW.status = 'open' AND NEW.lock_strategy = 'bounce'
    AND (SELECT period_status FROM public.game_state WHERE id = 1) = 'live' THEN
    RAISE EXCEPTION 'A bounce-locked market cannot be open during live play';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER markets_bounce_lock_guard
  BEFORE INSERT OR UPDATE ON public.markets
  FOR EACH ROW EXECUTE FUNCTION public.kennel_guard_market_bounce_lock();

-- Guard two: the same invariant from the other side. Play cannot resume while a
-- bounce-locked market is still open, so the two guards together close the window.
CREATE FUNCTION public.kennel_guard_live_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NEW.period_status = 'live' AND OLD.period_status IS DISTINCT FROM 'live'
    AND EXISTS (SELECT 1 FROM public.markets WHERE status = 'open' AND lock_strategy = 'bounce') THEN
    RAISE EXCEPTION 'Lock every bounce-locked market before play resumes';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER game_state_live_transition_guard
  BEFORE UPDATE ON public.game_state
  FOR EACH ROW EXECUTE FUNCTION public.kennel_guard_live_transition();

-- The opening bounce locks every bounce market, in the transaction that starts play.
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
  locked_market record;
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

  -- Lock the break markets before play resumes, so the live-transition guard passes
  -- and Studs stays closed for the whole quarter it covers.
  FOR locked_market IN
    UPDATE public.markets SET status = 'locked', updated_at = clock_timestamp()
    WHERE status = 'open' AND lock_strategy = 'bounce'
    RETURNING id
  LOOP
    PERFORM public.kennel_emit_event('market_updated',
      jsonb_build_object('marketId', locked_market.id, 'status', 'locked'));
  END LOOP;

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

-- A stale `open` bounce row can never take a stake, even if one somehow survives.
CREATE OR REPLACE FUNCTION public.kennel_place_bet(p_token_hash text, p_market_id uuid, p_option_id uuid,
  p_stake_delta integer, p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE p public.players%ROWTYPE; m public.markets%ROWTYPE; b public.bets%ROWTYPE;
  paused boolean; period text; cached jsonb; result jsonb;
BEGIN
  SELECT betting_paused, period_status INTO paused, period FROM public.game_state WHERE id = 1 FOR UPDATE;
  SELECT * INTO p FROM public.players WHERE session_token_hash = p_token_hash FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player session is no longer valid'; END IF;
  SELECT response INTO cached FROM public.mutation_receipts WHERE action = 'place_bet'
    AND idempotency_key = p_request_id AND actor_fingerprint = p_token_hash;
  IF FOUND THEN RETURN cached; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A valid idempotency key is required'; END IF;
  SELECT * INTO m FROM public.markets WHERE id = p_market_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Market not found'; END IF;
  IF m.status IN ('settled','void') THEN RAISE EXCEPTION 'Market is already settled or void'; END IF;
  IF m.status <> 'open' THEN RAISE EXCEPTION 'Market has locked'; END IF;
  -- A NULL locks_at on a deadline market would make the old comparison NULL, and so
  -- silently accept the stake. Test each strategy explicitly instead.
  IF m.lock_strategy = 'deadline' AND (m.locks_at IS NULL OR clock_timestamp() >= m.locks_at) THEN
    RAISE EXCEPTION 'Market has locked';
  END IF;
  IF m.lock_strategy = 'bounce' AND period = 'live' THEN RAISE EXCEPTION 'Market has locked'; END IF;
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
