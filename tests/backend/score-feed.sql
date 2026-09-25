-- Score feed assertions: host-only, validated, latest reading wins, host-only visibility.
DO $test$
DECLARE
  suffix text := substr(gen_random_uuid()::text, 1, 8);
  host_hash text := repeat('h', 32) || suffix;
  s jsonb;
BEGIN
  INSERT INTO public.host_sessions(token_hash, expires_at) VALUES(host_hash, now() + interval '1 hour');

  BEGIN
    PERFORM public.kennel_record_feed(repeat('x', 40), 38729, 1, 0, 0, 0, 'Q1 1:00', 1);
    RAISE EXCEPTION 'a feed reading was accepted without a host session';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Host session is no longer valid' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.kennel_record_feed(host_hash, 38729, -1, 0, 0, 0, 'Q1 1:00', 1);
    RAISE EXCEPTION 'a negative feed reading was accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'Invalid feed reading' THEN RAISE; END IF;
  END;

  PERFORM public.kennel_record_feed(host_hash, 38729, 1, 0, 0, 1, 'Q1 4:10', 5);
  PERFORM public.kennel_record_feed(host_hash, 38729, 2, 1, 0, 1, 'Q1 9:30', 10);
  s := public.kennel_host_snapshot(host_hash);
  IF (s#>>'{scoreFeed,homeGoals}')::int <> 2 OR (s#>>'{scoreFeed,homeBehinds}')::int <> 1
    OR s#>>'{scoreFeed,timeLabel}' <> 'Q1 9:30' OR (SELECT count(*) FROM public.score_feed) <> 1 THEN
    RAISE EXCEPTION 'the latest feed reading should replace the previous one: %', s->'scoreFeed';
  END IF;
  IF public.kennel_public_snapshot() ? 'scoreFeed' THEN
    RAISE EXCEPTION 'guests must not see the feed';
  END IF;
  -- The feed never touches the app's own score.
  IF EXISTS (SELECT 1 FROM public.score_events WHERE created_at >= now()) THEN
    RAISE EXCEPTION 'a feed reading created a score event';
  END IF;

  RAISE EXCEPTION 'SCORE_FEED_ASSERTIONS_PASSED_ROLLED_BACK';
END
$test$;
