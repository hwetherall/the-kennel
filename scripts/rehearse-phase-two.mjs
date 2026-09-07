// Real HTTP mutations and 60 concurrent synthetic guests, exclusively on an empty rehearsal branch.
// Run: node scripts/rehearse-phase-two.mjs --run; interrupted run: --cleanup.
import assert from 'node:assert/strict'
import { verifyPreview } from './verify-phase-two-preview.mjs'
import { execFileSync } from 'node:child_process'
import { randomBytes, randomUUID, createHash } from 'node:crypto'
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs'
const cli = (...args) => {
  try { return JSON.parse(execFileSync('npx', ['-y', '@insforge/cli', '--json', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 8 * 1024 * 1024 })) }
  catch (error) {
    // Retain diagnostics locally, never stream SQL or credentials into tool output.
    writeFileSync('.env.rehearsal-error.local', String(error.stderr ?? error.message), { mode: 0o600 })
    throw new Error(`InsForge ${args[0]} ${args[1]} failed; diagnostics saved locally`)
  }
}
const query = (sql) => cli('db', 'query', '--', sql)
const literal = (value) => `'${JSON.stringify(value).replaceAll("'", "''")}'::jsonb`
assert(['--run', '--smoke', '--cleanup'].includes(process.argv[2]) && process.argv.length === 3, 'Use --run, --smoke or --cleanup')
const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
const branch = cli('branch', 'list').data.find((b) => b.id === project.project_id)
assert(branch?.name === 'phase-2-kennel' && branch.branch_state === 'ready' && branch.parent_project_id && branch.appkey !== 'bk8ptwjs', 'Refusing anything except ready phase-2-kennel')
assert.equal(project.oss_host, `https://${branch.appkey}.${branch.region}.insforge.app`)
const manifestFile = '.env.rehearsal.local'
const url = `https://${branch.appkey}.function2.insforge.app/kennel-api`
function cleanup(manifest) {
  assert.equal(manifest.branchId, branch.id)
  assert.match(manifest.prefix, /^LOAD[0-9a-f]{8}_$/)
  // No CASCADE: an unknown future foreign key must stop cleanup, not remove unrelated data.
  query(`DO $cleanup$ DECLARE saved_players jsonb; next_version bigint; BEGIN
    PERFORM 1 FROM public.game_state WHERE id=1 FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.players WHERE id NOT IN (SELECT id FROM jsonb_populate_recordset(NULL::public.players, ${literal(manifest.players)})) AND nickname NOT LIKE '${manifest.prefix.replaceAll('_', '\\_')}%' ESCAPE '\\')
      OR EXISTS (SELECT 1 FROM public.squares_purchases) OR EXISTS (SELECT 1 FROM public.square_import_batches)
      OR EXISTS (SELECT 1 FROM public.mutation_receipts WHERE actor_fingerprint NOT IN (
        SELECT session_token_hash FROM public.players UNION ALL SELECT '${manifest.hostHash || ''}'))
    THEN RAISE EXCEPTION 'Cleanup refused: non-rehearsal data'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_populate_recordset(NULL::public.players, ${literal(manifest.players)}) saved
      LEFT JOIN public.players current ON current.id=saved.id WHERE (to_jsonb(current)-'updated_at') IS DISTINCT FROM (to_jsonb(saved)-'updated_at'))
      OR (SELECT COALESCE(jsonb_agg(l ORDER BY sequence),'[]'::jsonb) FROM public.ledger l
        WHERE player_id IN (SELECT id FROM jsonb_populate_recordset(NULL::public.players, ${literal(manifest.players)}))) <> ${literal(manifest.ledger)}
    THEN RAISE EXCEPTION 'Cleanup refused: existing guest changed during rehearsal'; END IF;
    SELECT COALESCE(jsonb_agg(p),'[]'::jsonb) INTO saved_players FROM public.players p
      WHERE id IN (SELECT id FROM jsonb_populate_recordset(NULL::public.players, ${literal(manifest.players)}));
    SELECT version+1 INTO next_version FROM public.game_state WHERE id=1;
    TRUNCATE public.ledger, public.bets, public.market_options, public.markets,
      public.score_events, public.quarter_results, public.mutation_receipts, public.players,
      public.squares_purchases, public.square_import_batches, public.squares, public.game_state;
    INSERT INTO public.players SELECT * FROM jsonb_populate_recordset(NULL::public.players, saved_players);
    INSERT INTO public.ledger OVERRIDING SYSTEM VALUE SELECT * FROM jsonb_populate_recordset(NULL::public.ledger, ${literal(manifest.ledger)}) ORDER BY sequence;
    INSERT INTO public.game_state SELECT * FROM jsonb_populate_record(NULL::public.game_state, ${literal(manifest.game)});
    UPDATE public.game_state SET version=next_version, updated_at=clock_timestamp() WHERE id=1;
    INSERT INTO public.squares SELECT * FROM jsonb_populate_recordset(NULL::public.squares, ${literal(manifest.squares)});
    DELETE FROM public.game_events WHERE id > ${Number(manifest.event_checkpoint)};
    DELETE FROM public.host_sessions WHERE token_hash = '${manifest.hostHash || ''}';
  END $cleanup$;`)
  unlinkSync(manifestFile)
  console.log('Synthetic economic rows removed; original game and Squares restored; ledger guard remains enabled.')
}
if (process.argv[2] === '--cleanup') { cleanup(JSON.parse(readFileSync(manifestFile, 'utf8'))); process.exit(0) }
assert(!existsSync(manifestFile), 'A rehearsal manifest exists. Run --cleanup first.')
const baseline = query(`SELECT row_to_json(g) AS game,
 (SELECT COALESCE(max(id),0) FROM public.game_events) AS event_checkpoint,
 (SELECT jsonb_agg(s ORDER BY id) FROM public.squares s) AS squares,
 (SELECT COALESCE(jsonb_agg(p ORDER BY id),'[]'::jsonb) FROM public.players p) AS players,
 (SELECT COALESCE(jsonb_agg(l ORDER BY sequence),'[]'::jsonb) FROM public.ledger l) AS ledger,
 (SELECT count(*) FROM public.markets)+(SELECT count(*) FROM public.score_events)+
 (SELECT count(*) FROM public.quarter_results)+(SELECT count(*) FROM public.mutation_receipts)+
 (SELECT count(*) FROM public.squares_purchases)+(SELECT count(*) FROM public.square_import_batches) AS existing
 FROM public.game_state g WHERE id=1`).rows[0]
assert.equal(Number(baseline.existing), 0, 'Rehearsal requires empty event tables; existing data is never removed to make room')
assert.equal(baseline.game.period_status, 'pre_match')
const manifest = { ...baseline, branchId: branch.id, prefix: `LOAD${randomBytes(4).toString('hex')}_`, hostHash: '' }
writeFileSync(manifestFile, JSON.stringify(manifest), { mode: 0o600 })
async function batch(promises) {
  const results = await Promise.allSettled(promises)
  const failed = results.find((r) => r.status === 'rejected')
  if (failed) throw failed.reason
  return results.map((r) => r.value)
}
const guestCount = process.argv[2] === '--smoke' ? 2 : 60
const timings = []; let calls = 0; let expectedRejections = 0
async function call(action, payload = {}, auth = {}, key, status = 200) {
  const started = performance.now()
  const response = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...auth, ...(key ? { 'Idempotency-Key': key } : {}) },
    body: JSON.stringify({ action, ...payload }), signal: AbortSignal.timeout(30_000) })
  const result = await response.json()
  timings.push(performance.now() - started); calls++
  assert.equal(response.status, status, `${action}: ${result.error ?? 'unexpected HTTP status'}`)
  if (status !== 200) expectedRejections++
  return result.data
}
let host
try {
  const secret = cli('secrets', 'get', 'HOST_PIN')
  const pin = secret.value ?? secret.secret?.value ?? secret.data?.value
  assert(typeof pin === 'string', 'Could not read configured branch PIN; no value was printed')
  const login = await call('host_login', { pin })
  manifest.hostHash = createHash('sha256').update(login.token).digest('hex')
  writeFileSync(manifestFile, JSON.stringify(manifest), { mode: 0o600 })
  host = { 'X-Host-Token': login.token }
  const guests = Array.from({ length: guestCount }, (_, i) => ({ token: randomBytes(32).toString('hex'), nickname: `${manifest.prefix}${i}`, index: i }))
  const joined = await batch(guests.map((g) => call('join', { nickname: g.nickname, sessionToken: g.token })))
  joined.forEach((s) => assert.equal(s.player.balance, 1000))
  const rejoin = await call('join', { nickname: guests[0].nickname, sessionToken: guests[0].token })
  assert.equal(rejoin.player.balance, 1000)
  let snapshot = await call('start_quarter', { quarter: 1 }, host, randomUUID())
  const first = snapshot.activeMarket
  const intents = guests.map((g) => ({ marketId: first.id, optionId: first.options[g.index % 2].id, stake: 25 * (1 + g.index % 4) }))
  // Repeated keys deliberately overlap their first request. Other guests and reads run simultaneously.
  const requests = guests.map((g) => ({ auth: { 'X-Player-Token': g.token }, key: randomUUID() }))
  await batch(guests.flatMap((g, i) => [call('place_bet', intents[i], requests[i].auth, requests[i].key),
    ...(i < 10 ? [call('place_bet', intents[i], requests[i].auth, requests[i].key)] : []),
    call(i % 2 ? 'public_snapshot' : 'player_snapshot', {}, i % 2 ? {} : requests[i].auth)]))
  const expectedPool = intents.reduce((n, b) => n + b.stake, 0)
  snapshot = await call('host_snapshot', {}, host)
  assert.equal(snapshot.activeMarket.totalPoolBones, expectedPool)
  assert.equal(snapshot.activeMarket.betCount, guestCount)
  await batch([call('place_bet', { ...intents[0], stake: 25 }, requests[0].auth, randomUUID()), call('place_bet', { ...intents[0], stake: 25 }, requests[0].auth, randomUUID())])
  await call('place_bet', { ...intents[0], optionId: first.options[1].id }, requests[0].auth, randomUUID(), 400)
  await call('place_bet', { ...intents[0], stake: 2000 }, requests[0].auth, randomUUID(), 400)
  await call('set_pause', { paused: true }, host, randomUUID())
  await call('place_bet', intents[0], requests[0].auth, randomUUID(), 400)
  snapshot = await call('record_score', { team: 'away', scoreType: 'behind' }, host, randomUUID())
  assert.equal(snapshot.activeMarket.id, first.id)
  await call('set_pause', { paused: false }, host, randomUUID())
  await call('lock_market', { marketId: first.id }, host, randomUUID())
  await call('place_bet', { ...intents[0], clientTime: '2000-01-01' }, requests[0].auth, randomUUID(), 400)
  const goalKey = randomUUID()
  snapshot = await call('record_score', { team: 'home', scoreType: 'goal' }, host, goalKey)
  const successor = snapshot.activeMarket
  const retried = await call('record_score', { team: 'home', scoreType: 'goal' }, host, goalKey)
  assert.equal(retried.activeMarket.id, successor.id)
  await call('place_bet', { marketId: successor.id, optionId: successor.options[1].id, stake: 100 }, requests[0].auth, randomUUID())
  const undoKey = randomUUID()
  snapshot = await call('undo_latest_score', {}, host, undoKey)
  assert.equal(snapshot.activeMarket.id, first.id)
  assert.equal(snapshot.game.homePoints, 0); assert.equal(snapshot.game.awayPoints, 1)
  await call('undo_latest_score', {}, host, undoKey)
  const recovered = await call('player_snapshot', {}, requests[0].auth)
  assert.equal(recovered.player.balance, 925)
  snapshot = await call('record_score', { team: 'home', scoreType: 'goal' }, host, randomUUID())
  const sirenKey = randomUUID()
  snapshot = await call('end_quarter', {}, host, sirenKey)
  const frozen = snapshot.quarterResults[0].quarterLadder
  assert.equal(snapshot.game.periodStatus, 'break'); assert.equal(snapshot.activeMarket, null)
  const sirenRetry = await call('end_quarter', {}, host, sirenKey)
  assert.deepEqual(sirenRetry.quarterResults[0].quarterLadder, frozen)
  await call('start_quarter', { quarter: 2 }, host, randomUUID())
  snapshot = await call('host_snapshot', {}, host)
  assert.deepEqual(snapshot.quarterResults[0].quarterLadder, frozen)
  assert(snapshot.quarterLadder.every((p) => p.profit === 0))
  console.log(`Authenticated ${guestCount}-player HTTP flows passed; checking the live preview next.`)
  await verifyPreview({ appUrl: 'https://bk8ptwjs-zww.insforge.site', guest: guests[0], opponent: guests[1], hostSession: login })
  const invariants = query(`SELECT
    NOT EXISTS (SELECT 1 FROM public.players p WHERE balance <> (SELECT COALESCE(sum(amount),0) FROM public.ledger l WHERE l.player_id=p.id)) AS balances,
    NOT EXISTS (SELECT 1 FROM public.market_options o WHERE pool_bones <> (SELECT COALESCE(sum(stake),0) FROM public.bets b WHERE b.option_id=o.id)) AS pools,
    NOT EXISTS (SELECT 1 FROM public.markets m WHERE settled_at IS NOT NULL AND
      (SELECT COALESCE(sum(payout),0) FROM public.bets b WHERE b.market_id=m.id)+settlement_dust_bones <>
      (SELECT COALESCE(sum(stake),0) FROM public.bets b WHERE b.market_id=m.id)) AS conservation,
    NOT EXISTS (SELECT 1 FROM public.ledger l JOIN public.ledger r ON l.reversal_of_id=r.id WHERE l.amount <> -r.amount OR l.player_id<>r.player_id) AS reversals,
    (SELECT tgenabled = 'O' FROM pg_trigger WHERE tgname='ledger_immutable') AS ledger_guard`).rows[0]
  assert(Object.values(invariants).every((value) => value === true), JSON.stringify(invariants))
  timings.sort((a, b) => a - b)
  const report = { guests: guestCount, loadGate: guestCount === 60, calls, expectedRejections, errors: 0,
    latencyMs: { p50: Math.round(timings[Math.floor(timings.length * .5)]), p95: Math.round(timings[Math.floor(timings.length * .95)]), max: Math.round(timings.at(-1)) }, invariants }
  writeFileSync(guestCount === 60 ? 'phase-2-rehearsal-results.json' : 'phase-2-smoke-results.json', JSON.stringify(report, null, 2) + '\n')
  console.log(JSON.stringify(report, null, 2))
} catch (error) {
  console.error(error.message)
  throw error
} finally { cleanup(manifest) }
