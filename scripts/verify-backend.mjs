const functionUrl = process.env.KENNEL_FUNCTION_URL
const pin = process.env.HOST_PIN

if (!functionUrl || !pin) {
  throw new Error('KENNEL_FUNCTION_URL and HOST_PIN are required')
}

async function call(action, body = {}, headers = {}) {
  const response = await fetch(functionUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify({ action, ...body }),
  })
  const payload = await response.json()
  if (!response.ok || payload.error) throw new Error(`${action}: ${payload.error || response.statusText}`)
  return payload.data
}

const publicSnapshot = await call('public_snapshot')
if (publicSnapshot.squares.length !== 100) throw new Error('Public snapshot did not return 100 squares')

const suffix = crypto.randomUUID().slice(0, 6)
const playerToken = `${crypto.randomUUID()}${crypto.randomUUID()}`
const joined = await call('join', {
  nickname: `Verifier-${suffix}`,
  claimEmail: '',
  sessionToken: playerToken,
})
if (joined.player.nickname !== `Verifier-${suffix}`) throw new Error('Player join did not return the new player')

const restored = await call('player_snapshot', {}, { 'X-Player-Token': playerToken })
if (restored.player.id !== joined.player.id) throw new Error('Player session could not be restored')

const hostSession = await call('host_login', { pin })
const hostHeaders = { 'X-Host-Token': hostSession.token }
let host = await call('host_snapshot', {}, hostHeaders)

if (host.game.periodStatus === 'pre_match') {
  host = await call('start_quarter', { quarter: 1 }, {
    ...hostHeaders,
    'Idempotency-Key': crypto.randomUUID(),
  })
} else if (host.game.periodStatus === 'break' && host.game.quarter < 4) {
  host = await call('start_quarter', { quarter: host.game.quarter + 1 }, {
    ...hostHeaders,
    'Idempotency-Key': crypto.randomUUID(),
  })
}

if (host.game.periodStatus === 'live') {
  const initialPoints = host.game.homePoints
  const scoreKey = crypto.randomUUID()
  const scored = await call('record_score', { team: 'home', scoreType: 'goal' }, {
    ...hostHeaders,
    'Idempotency-Key': scoreKey,
  })
  const scoredAgain = await call('record_score', { team: 'home', scoreType: 'goal' }, {
    ...hostHeaders,
    'Idempotency-Key': scoreKey,
  })
  if (scored.game.homePoints !== initialPoints + 6 || scoredAgain.game.homePoints !== scored.game.homePoints) {
    throw new Error('Idempotent score entry failed')
  }

  const undoKey = crypto.randomUUID()
  const undone = await call('undo_latest_score', {}, { ...hostHeaders, 'Idempotency-Key': undoKey })
  const undoneAgain = await call('undo_latest_score', {}, { ...hostHeaders, 'Idempotency-Key': undoKey })
  if (undone.game.homePoints !== initialPoints || undoneAgain.game.homePoints !== initialPoints) {
    throw new Error('Idempotent score undo failed')
  }

  const paused = await call('set_pause', { paused: true }, {
    ...hostHeaders,
    'Idempotency-Key': crypto.randomUUID(),
  })
  if (!paused.game.bettingPaused) throw new Error('Pause did not take effect')
  await call('set_pause', { paused: false }, {
    ...hostHeaders,
    'Idempotency-Key': crypto.randomUUID(),
  })

  const finalScore = await call('record_score', { team: 'away', scoreType: 'behind' }, {
    ...hostHeaders,
    'Idempotency-Key': crypto.randomUUID(),
  })
  const ended = await call('end_quarter', {}, {
    ...hostHeaders,
    'Idempotency-Key': crypto.randomUUID(),
  })
  if (!ended.quarterResults.some((result) => result.quarter === finalScore.game.quarter)) {
    throw new Error('Quarter result was not recorded')
  }
}

console.log(JSON.stringify({
  publicSquares: publicSnapshot.squares.length,
  playerJoin: 'ok',
  playerSession: 'ok',
  hostSession: 'ok',
  scoreIdempotency: 'ok',
  undoIdempotency: 'ok',
  pause: 'ok',
  quarterSettlement: 'ok',
}, null, 2))
