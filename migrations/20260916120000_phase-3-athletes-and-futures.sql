-- Phase 3, step 2: athletes, the Futures shape, and the quarter-ladder split.
--
-- Futures are built before Studs v Spuds deliberately. They are the smaller of
-- the two features and they exercise the same bounce-lock rule that step 1
-- introduced, so Studs inherits a proven lock path rather than a theory.
--
-- One athletes table serves both features: Studs matchups name two athletes, and
-- Norm Smith candidates are athletes too. Entering a player once is what keeps a
-- typo from creating a second identity for the same person, which matters because
-- the Studs baseline carry-forward rule compares athlete identity across quarters.

-- ---------------------------------------------------------------------------
-- Athletes
-- ---------------------------------------------------------------------------

CREATE TABLE public.athletes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 80),
  team_label text CHECK (team_label IS NULL OR length(btrim(team_label)) BETWEEN 1 AND 40),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Case- and whitespace-insensitive, so "Marcus Bontempelli" entered twice at the
-- bar at 11pm resolves to one athlete rather than two.
CREATE UNIQUE INDEX athletes_display_name_key
  ON public.athletes (lower(btrim(display_name)));

ALTER TABLE public.athletes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "client access denied" ON public.athletes
  FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- ---------------------------------------------------------------------------
-- Market options can name an athlete
-- ---------------------------------------------------------------------------

-- RESTRICT, not CASCADE: an athlete carrying stakes must never vanish and take
-- the option out from under a settled bet.
ALTER TABLE public.market_options
  ADD COLUMN athlete_id uuid REFERENCES public.athletes(id) ON DELETE RESTRICT;

CREATE INDEX market_options_athlete_idx
  ON public.market_options(athlete_id) WHERE athlete_id IS NOT NULL;

-- Exactly one "Any other player" per market, enforced declaratively. Its key is
-- deliberately not an athlete id, so a real candidate can never collide with it.
CREATE UNIQUE INDEX market_options_any_other_player_idx
  ON public.market_options(market_id) WHERE option_key = 'any_other_player';

-- option_key was a two-team literal in Phase 2. Each market type now has its own
-- key shape, and a CHECK cannot see the parent market's type, so this is a trigger.
CREATE FUNCTION public.kennel_guard_market_option_key() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE market_type text;
BEGIN
  SELECT type INTO market_type FROM public.markets WHERE id = NEW.market_id;
  IF market_type IS NULL THEN
    RAISE EXCEPTION 'Option references a market that does not exist';
  END IF;

  IF market_type IN ('next_goal', 'futures_winner') THEN
    IF NEW.option_key NOT IN ('home', 'away') THEN
      RAISE EXCEPTION 'A % option must be keyed home or away', market_type;
    END IF;
    IF NEW.athlete_id IS NOT NULL THEN
      RAISE EXCEPTION 'A team option cannot name an athlete';
    END IF;

  ELSIF market_type = 'studs_v_spuds' THEN
    IF NEW.option_key NOT IN ('athlete_a', 'athlete_b') THEN
      RAISE EXCEPTION 'A Studs option must be keyed athlete_a or athlete_b';
    END IF;
    IF NEW.athlete_id IS NULL THEN
      RAISE EXCEPTION 'A Studs option must name an athlete';
    END IF;

  ELSIF market_type = 'futures_norm_smith' THEN
    IF NEW.option_key = 'any_other_player' THEN
      IF NEW.athlete_id IS NOT NULL THEN
        RAISE EXCEPTION 'The any-other-player option must not name an athlete';
      END IF;
    ELSE
      IF NEW.athlete_id IS NULL THEN
        RAISE EXCEPTION 'A Norm Smith candidate must name an athlete';
      END IF;
      -- A stable, derivable key, so the same candidate always has the same key.
      IF NEW.option_key <> 'athlete:' || NEW.athlete_id::text THEN
        RAISE EXCEPTION 'A Norm Smith candidate must be keyed athlete:<athlete id>';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER market_options_key_guard
  BEFORE INSERT OR UPDATE ON public.market_options
  FOR EACH ROW EXECUTE FUNCTION public.kennel_guard_market_option_key();

-- ---------------------------------------------------------------------------
-- Futures shape
-- ---------------------------------------------------------------------------

-- Exactly one match-winner and one Norm Smith for the event. A voided Future is
-- still that Future; there is no second attempt.
CREATE UNIQUE INDEX markets_single_future_idx ON public.markets(type)
  WHERE type IN ('futures_winner', 'futures_norm_smith');

-- Futures belong to no quarter and can never decide a quarter prize, per the
-- rule that a bet placed at 10:30pm must not decide the Q4 ladder.
ALTER TABLE public.markets ADD CONSTRAINT markets_futures_shape CHECK (
  type NOT IN ('futures_winner', 'futures_norm_smith')
  OR (quarter IS NULL AND counts_toward_quarter_prize = false)
);

-- A Studs market always belongs to the quarter it covers.
ALTER TABLE public.markets ADD CONSTRAINT markets_studs_shape CHECK (
  type <> 'studs_v_spuds' OR quarter IS NOT NULL
);

-- ---------------------------------------------------------------------------
-- Quarter ladder finalization, separate from the Squares result
-- ---------------------------------------------------------------------------

-- The siren seals the Squares result immediately; the quarter ladder can only be
-- final once every Studs matchup for that quarter is resolved. Two timestamps,
-- because disposal lookup must never hold up the Squares siren.
--
-- The DEFAULT preserves Phase 2 behaviour exactly: end_quarter does not name this
-- column, so a quarter with no Studs market finalizes its ladder at the siren,
-- as it does today. When Studs lands, that path will pass an explicit NULL for a
-- quarter whose matchups are still pending. This is the seam, and it is deliberate.
ALTER TABLE public.quarter_results
  ADD COLUMN ladder_finalized_at timestamptz DEFAULT now();

-- Every quarter settled under Phase 2 was final the moment it was written.
UPDATE public.quarter_results
  SET ladder_finalized_at = settled_at
  WHERE ladder_finalized_at IS NULL OR ladder_finalized_at <> settled_at;

-- A finalized ladder must have standings behind it.
ALTER TABLE public.quarter_results ADD CONSTRAINT quarter_results_ladder_finalization CHECK (
  ladder_finalized_at IS NULL OR quarter_ladder IS NOT NULL
);
