// Loads the Grand Final night's Kennel setup through the same host actions the
// console uses: team names, athletes, both Futures, and the four Studs rounds.
// Safe to re-run: anything already opened is left alone.
//
//   HOST_PIN=... node --env-file=.env.local scripts/setup-grand-final.mjs
//
// It targets KENNEL_FUNCTION_URL, and names that target before changing anything.
import { randomUUID } from 'node:crypto'

const HOME_TEAM = 'Fremantle'
const AWAY_TEAM = 'Brisbane'

// Norm Smith shortlist, in the order of the club's odds sheet. "Any other player"
// is added by the server.
const NORM_SMITH = [
  ['Will Ashcroft', 'BRI'], ['Lachie Neale', 'BRI'], ['Luke Jackson', 'FRE'], ['Zac Bailey', 'BRI'], ['Caleb Serong', 'FRE'],
  ['Hugh McCluggage', 'BRI'], ['Andrew Brayshaw', 'FRE'], ['Dayne Zorko', 'BRI'], ['Shai Bolton', 'FRE'],
  ['Hayden Young', 'FRE'], ['Josh Dunkley', 'BRI'],
]

// One round per quarter. Paired on 2026 season and last-five-game averages
// (AFL Tables); the ruck round uses hit-outs because rucks' disposals are lopsided.
const ROUNDS = [
  { quarter: 1, label: 'Ruck Round', stat: 'hitouts', pairs: [
    [['Luke Jackson', 'FRE'], ['Sam Draper', 'BRI']],
    [['Mason Cox', 'FRE'], ['Darcy Fort', 'BRI']],
  ] },
  { quarter: 2, label: 'Forwards Round', stat: 'disposals', pairs: [
    [['Shai Bolton', 'FRE'], ['Zac Bailey', 'BRI']],
    [['Josh Treacy', 'FRE'], ['Eric Hipwood', 'BRI']],
    [['Michael Frederick', 'FRE'], ['Charlie Cameron', 'BRI']],
  ] },
  { quarter: 3, label: 'Midfield Round', stat: 'disposals', pairs: [
    [['Andrew Brayshaw', 'FRE'], ['Will Ashcroft', 'BRI']],
    [['Caleb Serong', 'FRE'], ['Lachie Neale', 'BRI']],
    [['Hayden Young', 'FRE'], ['Josh Dunkley', 'BRI']],
  ] },
  { quarter: 4, label: 'Back Round', stat: 'disposals', pairs: [
    [['Jordan Clark', 'FRE'], ['Dayne Zorko', 'BRI']],
    [['Luke Ryan', 'FRE'], ['Darcy Wilmot', 'BRI']],
    [['Heath Chapman', 'FRE'], ['Ryan Lester', 'BRI']],
  ] },
]

const url = process.env.KENNEL_FUNCTION_URL
const pin = process.env.HOST_PIN
if (!url || !pin) {
  console.error('KENNEL_FUNCTION_URL (in .env.local) and HOST_PIN are required')
  process.exit(1)
}
console.log(`Target: ${url}`)

async function call(action, payload = {}, token) {
  const headers = { 'Content-Type': 'application/json' }
  if (token) { headers['X-Host-Token'] = token; headers['Idempotency-Key'] = randomUUID() }
  const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ action, ...payload }) })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(`${action}: ${body.error ?? response.status}`)
  return body.data
}

const { token } = await call('host_login', { pin })
let snapshot = await call('host_snapshot', {}, token)

if (snapshot.event.homeTeam !== HOME_TEAM || snapshot.event.awayTeam !== AWAY_TEAM) {
  snapshot = await call('set_grid', { homeTeam: HOME_TEAM, awayTeam: AWAY_TEAM,
    rowDigits: snapshot.grid.rowDigits, colDigits: snapshot.grid.colDigits }, token)
  console.log(`Teams set: ${HOME_TEAM} (home, down the side) v ${AWAY_TEAM} (away, across the top)`)
}

const athletes = new Map([...NORM_SMITH, ...ROUNDS.flatMap((round) => round.pairs.flat())].map(([name, team]) => [name, team]))
snapshot = await call('ensure_athletes', { athletes: [...athletes].map(([name, team]) => ({ name, team })) }, token)
const idOf = (name) => snapshot.athletes.find((athlete) => athlete.name === name).id
console.log(`Athletes: ${snapshot.athletes.length}`)

if (snapshot.futures.every((market) => market.status === 'draft')) {
  snapshot = await call('configure_futures', { candidateIds: NORM_SMITH.map(([name]) => idOf(name)),
    matchMaxStake: 200, normSmithMaxStake: 200 }, token)
  console.log(`Futures configured: match winner, Norm Smith with ${NORM_SMITH.length} candidates plus Any other player`)
} else {
  console.log('Futures already open; left unchanged')
}

for (const round of ROUNDS) {
  for (const [index, [[a], [b]]] of round.pairs.entries()) {
    const existing = snapshot.studsMatchups.find((m) => m.quarter === round.quarter && m.slot === index + 1)
    if (existing?.marketId) { console.log(`Q${round.quarter} slot ${index + 1} already open; left unchanged`); continue }
    snapshot = await call('configure_studs_matchup', { quarter: round.quarter, slot: index + 1, roundLabel: round.label,
      stat: round.stat, athleteAId: idOf(a), athleteBId: idOf(b) }, token)
    console.log(`Q${round.quarter} ${round.label}: ${a} v ${b} (${round.stat})`)
  }
}
console.log('Done. Open Q1 Studs and both Futures from the host console before the first bounce.')
