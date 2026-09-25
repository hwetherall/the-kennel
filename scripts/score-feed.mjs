// Live score assist. Holds one connection to Squiggle's live event stream for
// the Grand Final and passes each running score to the Kennel, where the host
// console shows any difference from the app's own score as a one-tap confirm.
// The feed never scores anything itself.
//
//   HOST_PIN=... KENNEL_FUNCTION_URL=... npm run score-feed
//   SQUIGGLE_GAME=test ... npm run score-feed   # Squiggle's random test channel
//
// Squiggle asks bots to identify themselves with a contact; set SQUIGGLE_CONTACT
// to an email to include one in the User-Agent.
import { randomUUID } from 'node:crypto'
import { parseSseChunk, readingFrom } from './score-feed-parse.mjs'

const url = process.env.KENNEL_FUNCTION_URL
const pin = process.env.HOST_PIN
const game = process.env.SQUIGGLE_GAME ?? '38729' // 2026 Grand Final, Fremantle v Brisbane Lions
const testMode = game === 'test'
const userAgent = `Denver Bulldogs ARFC Kennel watch party${process.env.SQUIGGLE_CONTACT ? ` - ${process.env.SQUIGGLE_CONTACT}` : ''}`
if (!url || !pin) {
  console.error('KENNEL_FUNCTION_URL and HOST_PIN are required')
  process.exit(1)
}

let token = null
let swapped = false // true if Squiggle's home team is the app's away team
let latest = null
let connected = false

async function kennel(action, payload = {}) {
  const headers = { 'Content-Type': 'application/json' }
  if (token) { headers['X-Host-Token'] = token; headers['Idempotency-Key'] = randomUUID() }
  const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ action, ...payload }) })
  const body = await response.json().catch(() => ({}))
  if (response.status === 401 && action !== 'host_login') { token = null; throw new Error('host session expired') }
  if (!response.ok) throw new Error(`${action}: ${body.error ?? response.status}`)
  return body.data
}

async function login() {
  token = null
  token = (await kennel('host_login', { pin })).token
}

async function post(reading) {
  latest = reading
  const home = swapped ? { goals: reading.agoals, behinds: reading.abehinds } : { goals: reading.hgoals, behinds: reading.hbehinds }
  const away = swapped ? { goals: reading.hgoals, behinds: reading.hbehinds } : { goals: reading.agoals, behinds: reading.abehinds }
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      if (!token) await login()
      await kennel('record_feed', { sourceGameId: testMode ? 1 : Number(game), homeGoals: home.goals, homeBehinds: home.behinds,
        awayGoals: away.goals, awayBehinds: away.behinds, timeLabel: reading.timestr ?? null, complete: reading.complete ?? null })
      return
    } catch (error) {
      console.error(`  could not pass reading on (${error.message}); retrying`)
      await new Promise((resolve) => setTimeout(resolve, 1000 * (attempt + 1)))
    }
  }
}

function show(reading) {
  const pts = (g, b) => `${g}.${b} (${g * 6 + b})`
  console.log(`${new Date().toLocaleTimeString()}  ${reading.timestr ?? ''}  home ${pts(reading.hgoals, reading.hbehinds)}  away ${pts(reading.agoals, reading.abehinds)}`)
}

await login()
const snapshot = await kennel('host_snapshot')
console.log(`Kennel: ${url}\nApp teams: ${snapshot.event.homeTeam} (home) v ${snapshot.event.awayTeam} (away)`)

if (!testMode) {
  // One fetch of the game to check sides and seed the first reading.
  const response = await fetch(`https://api.squiggle.com.au/?q=games;game=${game}`, { headers: { 'User-Agent': userAgent } })
  const found = (await response.json()).games?.[0]
  if (!found) throw new Error(`Squiggle has no game ${game}`)
  const first = (label) => label.split(/\s+/)[0].toLowerCase()
  const appHome = first(snapshot.event.homeTeam)
  if (found.ateam.toLowerCase().startsWith(appHome)) swapped = true
  else if (!found.hteam.toLowerCase().startsWith(appHome)) {
    throw new Error(`Squiggle game ${game} is ${found.hteam} v ${found.ateam}, which does not match the app's home team`)
  }
  console.log(`Squiggle game ${game}: ${found.hteam} v ${found.ateam}${swapped ? ' (sides swapped to match the app)' : ''}`)
  const reading = readingFrom(found)
  if (reading) { show(reading); await post(reading) }
}

// While connected, refresh the reading every 30s so the console can tell a quiet
// game from a dead feed. Nothing is re-fetched from Squiggle.
setInterval(() => { if (connected && latest) void post(latest) }, 30_000)

let backoff = 2000
for (;;) {
  try {
    const response = await fetch(`https://sse.squiggle.com.au/${testMode ? 'test' : `events/${game}`}`, {
      headers: { 'User-Agent': userAgent, Accept: 'text/event-stream' },
    })
    if (!response.ok || !response.body) throw new Error(`Squiggle stream returned ${response.status}`)
    connected = true
    backoff = 2000
    console.log('Connected to the Squiggle live stream.')
    const decoder = new TextDecoder()
    let buffer = ''
    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true })
      const { events, rest } = parseSseChunk(buffer)
      buffer = rest
      for (const event of events) {
        const reading = readingFrom(event.data, event.event)
        if (reading) { show(reading); await post(reading) }
      }
    }
    throw new Error('stream closed')
  } catch (error) {
    connected = false
    console.error(`Squiggle stream: ${error.message}. Reconnecting in ${backoff / 1000}s.`)
    await new Promise((resolve) => setTimeout(resolve, backoff))
    backoff = Math.min(backoff * 2, 30_000)
  }
}
