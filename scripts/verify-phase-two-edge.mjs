// Read-only smoke checks of the deployed Phase 2 edge boundary.
import assert from 'node:assert/strict'
import { randomBytes, randomUUID } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
const { data: branches } = JSON.parse(execFileSync('npx', ['-y', '@insforge/cli', 'branch', 'list', '--json'], { encoding: 'utf8' }))
const branch = branches.find((entry) => entry.id === project.project_id)
assert(branch?.branch_state === 'ready', 'Switch to a ready development backend branch')
assert(branch.parent_project_id && branch.parent_project_id !== branch.id && branch.appkey !== 'bk8ptwjs', 'Refusing production')
assert.equal(project.oss_host, `https://${branch.appkey}.${branch.region}.insforge.app`)
const url = `https://${branch.appkey}.function2.insforge.app/kennel-api`
const invalidToken = randomBytes(32).toString('hex')
let checks = 0

async function call(body, headers = {}, expectedStatus = 200) {
  const response = await fetch(url, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body), signal: AbortSignal.timeout(20000),
  })
  const result = await response.json()
  assert.equal(response.status, expectedStatus, JSON.stringify(result))
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*')
  assert.equal(response.headers.get('Cache-Control'), 'no-store')
  checks += 1
  return result
}

const { data: snapshot } = await call({ action: 'public_snapshot' })
assert.equal(snapshot.squares.length, 100)
assert(Number.isFinite(Date.parse(snapshot.serverNow)))
for (const field of ['activeMarket', 'recentMarket', 'quarterLadder', 'topDogLadder']) assert(field in snapshot, `Missing ${field}`)
assert(!JSON.stringify(snapshot).match(/session_token|token_hash|purchaserEmail|claim_email/))
for (const body of [null, [], 'invalid']) await call(body, {}, 400)
const bet = { action: 'place_bet', marketId: randomUUID(), optionId: randomUUID(), stake: 25 }
await call(bet, {}, 401)
await call({ ...bet, stake: -1 }, { 'X-Player-Token': invalidToken, 'Idempotency-Key': randomUUID() }, 400)
await call({ ...bet, marketId: 'bad-id' }, { 'X-Player-Token': invalidToken, 'Idempotency-Key': randomUUID() }, 400)
const guestFailure = await call(bet, { 'X-Player-Token': invalidToken, 'Idempotency-Key': randomUUID() }, 401)
assert.equal(guestFailure.error, 'Player session is no longer valid')
for (const action of ['lock_market', 'settle_market', 'void_market', 'open_next_goal']) {
  await call({ action, marketId: bet.marketId, winningOptionId: bet.optionId, reason: 'Smoke check' }, {}, 401)
  const failure = await call({ action, marketId: bet.marketId, winningOptionId: bet.optionId, reason: 'Smoke check' }, {
    'X-Host-Token': invalidToken, 'Idempotency-Key': randomUUID(),
  }, 401)
  assert.equal(failure.error, 'Host session is no longer valid')
}
const preflight = await fetch(url, { method: 'OPTIONS', signal: AbortSignal.timeout(20000) })
assert.equal(preflight.status, 204)
assert(preflight.headers.get('Access-Control-Allow-Headers').includes('Idempotency-Key'))
console.log(`Phase 2 deployed edge: ${checks + 1} read-only smoke checks passed.`)
