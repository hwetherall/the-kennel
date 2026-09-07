// @vitest-environment node
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import handler from '../../functions/kennel-api'

const { databaseRpc, insert } = vi.hoisted(() => ({ databaseRpc: vi.fn(), insert: vi.fn() }))
vi.mock('npm:@insforge/sdk', () => ({
  createAdminClient: () => ({ database: { rpc: databaseRpc, from: () => ({ insert }) } }),
}))

const marketId = '11111111-1111-4111-8111-111111111111'
const optionId = '22222222-2222-4222-8222-222222222222'
const key = '33333333-3333-4333-8333-333333333333'
const token = 'a'.repeat(64)

function request(body: unknown, headers: Record<string, string> = {}) {
  return handler(new Request('https://example.invalid/kennel-api', {
    method: 'POST', body: JSON.stringify(body),
    headers: { 'Content-Type': 'application/json', ...headers },
  }))
}

afterEach(() => vi.useRealTimers())

beforeEach(() => {
  vi.clearAllMocks()
  vi.stubGlobal('Deno', { env: { get: (name: string) => ({
    INSFORGE_BASE_URL: 'https://example.invalid', API_KEY: 'server-only', HOST_PIN: '2468',
  })[name] } })
  databaseRpc.mockResolvedValue({ data: { game: { version: 3 }, player: { balance: 975 } }, error: null })
})

describe('Phase 2 edge boundary', () => {
  it('hashes the player token and forwards a stake intent with its retry key', async () => {
    const response = await request({ action: 'place_bet', marketId, optionId, stake: 25, balance: 999999 }, {
      'X-Player-Token': token, 'Idempotency-Key': key,
    })
    expect(response.status).toBe(200)
    expect(databaseRpc).toHaveBeenCalledWith('kennel_place_bet', {
      p_token_hash: expect.stringMatching(/^[a-f0-9]{64}$/), p_market_id: marketId,
      p_option_id: optionId, p_stake_delta: 25, p_request_id: key,
    })
    expect(databaseRpc.mock.calls[0][1].p_token_hash).not.toBe(token)
    expect(await response.json()).toEqual({ data: { game: { version: 3 }, player: { balance: 975 } } })
  })

  it.each([0, -1, 0.5, '25', null, 2147483648])('rejects invalid stake %s before the database', async (stake) => {
    const response = await request({ action: 'place_bet', marketId, optionId, stake }, {
      'X-Player-Token': token, 'Idempotency-Key': key,
    })
    expect(response.status).toBe(400)
    expect(databaseRpc).not.toHaveBeenCalled()
  })

  it('requires player authentication even with a host token', async () => {
    const response = await request({ action: 'place_bet', marketId, optionId, stake: 25 }, {
      'X-Host-Token': token, 'Idempotency-Key': key,
    })
    expect(response.status).toBe(401)
    expect(databaseRpc).not.toHaveBeenCalled()
  })

  it('requires a retry key and validates resource IDs', async () => {
    for (const [body, headers] of [
      [{ action: 'place_bet', marketId, optionId, stake: 25 }, { 'X-Player-Token': token }],
      [{ action: 'place_bet', marketId: 'bad', optionId, stake: 25 }, { 'X-Player-Token': token, 'Idempotency-Key': key }],
    ] as const) {
      expect((await request(body, headers)).status).toBe(400)
    }
    expect(databaseRpc).not.toHaveBeenCalled()
  })

  it.each(['lock_market', 'settle_market', 'void_market', 'open_next_goal'])('routes host recovery action %s', async (action) => {
    const response = await request({ action, marketId, winningOptionId: optionId, reason: 'Host correction' }, {
      'X-Host-Token': token, 'Idempotency-Key': key,
    })
    expect(response.status).toBe(200)
    expect(databaseRpc).toHaveBeenCalledWith('kennel_market_action', expect.objectContaining({
      p_action: action, p_request_id: key, p_lock_seconds: 90,
      p_market_id: action === 'open_next_goal' ? null : marketId,
      p_winning_option_id: action === 'settle_market' ? optionId : null,
    }))
  })

  it('does not let a guest call host recovery', async () => {
    expect((await request({ action: 'void_market', marketId, reason: 'Test' }, {
      'X-Player-Token': token, 'Idempotency-Key': key,
    })).status).toBe(401)
    expect(databaseRpc).not.toHaveBeenCalled()
  })

  it.each([
    { action: 'settle_market', marketId },
    { action: 'void_market', marketId, reason: '' },
    { action: 'open_next_goal', lockSeconds: 301 },
    { action: 'start_quarter', quarter: 5 },
    { action: 'record_score', team: ['home'], scoreType: 'goal' },
  ])('rejects invalid host intent %j', async (body) => {
    expect((await request(body, { 'X-Host-Token': token, 'Idempotency-Key': key })).status).toBe(400)
    expect(databaseRpc).not.toHaveBeenCalled()
  })

  it.each(['Market has locked', 'Betting is paused', 'Not enough Bones', 'Existing selection cannot be changed'])('preserves readable error: %s', async (message) => {
    databaseRpc.mockResolvedValue({ error: { message } })
    const response = await request({ action: 'place_bet', marketId, optionId, stake: 25 }, {
      'X-Player-Token': token, 'Idempotency-Key': key,
    })
    expect(response.status).toBe(400)
    expect(await response.json()).toEqual({ error: message })
  })

  it('does not expose SQL or internal error details', async () => {
    databaseRpc.mockResolvedValue({ error: { message: 'duplicate key on secret_table token=private' } })
    const response = await request({ action: 'public_snapshot' })
    expect(response.status).toBe(500)
    expect(await response.text()).not.toMatch(/secret_table|token=private|duplicate key/)
  })

  it('rejects malformed JSON and non-object bodies', async () => {
    for (const body of [null, [], 'hello']) expect((await request(body)).status).toBe(400)
    expect((await handler(new Request('https://example.invalid', { method: 'POST', body: '{' }))).status).toBe(400)
    expect(databaseRpc).not.toHaveBeenCalled()
  })
})

it.each(['53300', 'PGRST000'])('retries refused database connections (%s) with the same actor and stake key', async (code) => {
  vi.useFakeTimers()
  databaseRpc.mockResolvedValueOnce({ error: { code, message: 'Database connection error. Retrying the connection.' } })
    .mockResolvedValueOnce({ data: { accepted: true }, error: null })
  const pending = request({ action: 'place_bet', marketId, optionId, stake: 25 }, { 'X-Player-Token': token, 'Idempotency-Key': key })
  // Hashing uses WebCrypto; wait for the first RPC before advancing the retry clock.
  await vi.waitFor(() => expect(databaseRpc).toHaveBeenCalledTimes(1))
  await vi.runAllTimersAsync()
  expect((await pending).status).toBe(200)
  expect(databaseRpc.mock.calls[1]).toEqual(databaseRpc.mock.calls[0])
})
it('bounds capacity retries and returns a safe retryable error', async () => {
  vi.useFakeTimers()
  databaseRpc.mockResolvedValue({ error: { code: '53300', message: 'sorry, too many clients already' } })
  const pending = request({ action: 'public_snapshot' })
  await vi.runAllTimersAsync()
  const response = await pending
  expect(response.status).toBe(503)
  expect(databaseRpc).toHaveBeenCalledTimes(6)
  expect(await response.text()).not.toContain('clients')
})
