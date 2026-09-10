import { createClient } from '@insforge/sdk'
import type {
  GridConfig,
  HostSession,
  HostSnapshot,
  PlayerSnapshot,
  PublicSnapshot,
  ScoreType,
  TeamSide,
} from '../types'
import {
  demoEndQuarter,
  demoPlaceBet,
  demoMarketAction,
  demoMutation,
  demoHostSnapshot,
  demoPause,
  demoPlayerSnapshot,
  demoPublicSnapshot,
  demoRecordScore,
  demoSetGrid,
  demoStartQuarter,
  demoUndo,
} from './demo'

const baseUrl = import.meta.env.VITE_INSFORGE_URL
const anonKey = import.meta.env.VITE_INSFORGE_ANON_KEY
const demoMode = import.meta.env.VITE_DEMO_MODE === 'true'

export const backendConfigured = !demoMode && Boolean(baseUrl)

export const insforge = backendConfigured && anonKey
  ? createClient({ baseUrl: baseUrl!, anonKey: anonKey! })
  : null

function publicFunctionUrl() {
  const appKey = new URL(baseUrl!).hostname.split('.')[0]
  return `https://${appKey}.function2.insforge.app/kennel-api`
}

export class ApiError extends Error {
  constructor(message: string, public readonly uncertain: boolean) { super(message) }
}

const transientAttempts = 8

function waitForRetry(attempt: number) {
  const delay = 100 * 2 ** attempt + Math.floor(Math.random() * 200)
  return new Promise((resolve) => setTimeout(resolve, delay))
}

interface InvokeOptions {
  playerToken?: string
  hostToken?: string
  idempotencyKey?: string
}

async function invokeRaw<T>(action: string, payload = {}, options: InvokeOptions = {}) {
  if (!backendConfigured) throw new Error('Backend is not configured')

  const headers: Record<string, string> = {}
  if (options.playerToken) headers['X-Player-Token'] = options.playerToken
  if (options.hostToken) headers['X-Host-Token'] = options.hostToken
  if (options.idempotencyKey) headers['Idempotency-Key'] = options.idempotencyKey

  let data: unknown
  let error: { message?: string } | null = null

  if (insforge) {
    const response = await insforge.functions.invoke('kennel-api', {
      body: { action, ...payload },
      headers,
    })
    data = response.data
    error = response.error
  } else {
    const response = await fetch(publicFunctionUrl(), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify({ action, ...payload }),
      signal: AbortSignal.timeout(15_000),
    })
    data = await response.json().catch(() => null)
    if (!response.ok) {
      const message = data && typeof data === 'object' && 'error' in data
        ? String(data.error)
        : `The Kennel server returned ${response.status}`
      throw new ApiError(message, response.status >= 500 || response.status === 408)
    }
  }

  if (error) throw new ApiError(error.message || 'The Kennel could not reach the server', true)
  const response = data as { data?: T; error?: string } | T
  if (response && typeof response === 'object' && 'error' in response && response.error) {
    throw new Error(response.error)
  }
  if (response && typeof response === 'object' && 'data' in response) {
    return response.data as T
  }
  return response as T
}

async function invoke<T>(action: string, payload = {}, options: InvokeOptions = {}) {
  const storageKey = options.hostToken && options.idempotencyKey ? `kennel-pending-host:${options.hostToken}` : null
  if (storageKey) sessionStorage.setItem(storageKey, JSON.stringify({ action, payload, key: options.idempotencyKey }))
  for (let attempt = 0; attempt < transientAttempts; attempt += 1) {
    try {
      const result = await invokeRaw<T>(action, payload, options)
      if (storageKey) sessionStorage.removeItem(storageKey)
      return result
    } catch (error) {
      if (error instanceof ApiError && error.uncertain && attempt + 1 < transientAttempts) {
        await waitForRetry(attempt)
        continue
      }
      if (storageKey && error instanceof ApiError && !error.uncertain) sessionStorage.removeItem(storageKey)
      throw error
    }
  }
  throw new Error('Unreachable retry state')
}

export function pendingHostMutation(hostToken?: string) {
  if (!hostToken) return null
  try {
    const saved = JSON.parse(sessionStorage.getItem(`kennel-pending-host:${hostToken}`) ?? 'null')
    if (!saved) return null
    return { label: String(saved.action).replaceAll('_', ' '), key: String(saved.key),
      action: (key: string) => invoke<HostSnapshot>(saved.action, saved.payload, { hostToken, idempotencyKey: key }) }
  } catch { return null }
}

export async function getPublicSnapshot() {
  return backendConfigured
    ? invoke<PublicSnapshot>('public_snapshot')
    : demoPublicSnapshot()
}

export async function joinPlayer(
  nickname: string,
  claimEmail: string,
  sessionToken: string,
) {
  if (!backendConfigured) return demoPlayerSnapshot(sessionToken)
  return invoke<PlayerSnapshot>('join', { nickname, claimEmail, sessionToken })
}

export async function getPlayerSnapshot(playerToken: string) {
  return backendConfigured
    ? invoke<PlayerSnapshot>('player_snapshot', {}, { playerToken })
    : demoPlayerSnapshot(playerToken)
}

export async function hostLogin(pin: string): Promise<HostSession> {
  if (!backendConfigured) {
    if (pin !== '2468') throw new Error('For the local demo, use PIN 2468')
    return { token: 'demo-host', expiresAt: new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString() }
  }
  return invoke<HostSession>('host_login', { pin })
}

export async function getHostSnapshot(hostToken: string) {
  return backendConfigured
    ? invoke<HostSnapshot>('host_snapshot', {}, { hostToken })
    : demoHostSnapshot()
}

export async function recordScore(
  hostToken: string,
  team: TeamSide,
  scoreType: ScoreType,
  idempotencyKey: string,
) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoRecordScore(team, scoreType))
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('record_score', { team, scoreType }, { hostToken, idempotencyKey })
}

export async function undoLatestScore(hostToken: string, idempotencyKey: string) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoUndo())
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('undo_latest_score', {}, { hostToken, idempotencyKey })
}

export async function setPause(hostToken: string, paused: boolean, idempotencyKey: string) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoPause(paused))
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('set_pause', { paused }, { hostToken, idempotencyKey })
}

export async function startQuarter(hostToken: string, quarter: number, idempotencyKey: string) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoStartQuarter(quarter))
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('start_quarter', { quarter }, { hostToken, idempotencyKey })
}

export async function endQuarter(hostToken: string, idempotencyKey: string) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoEndQuarter())
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('end_quarter', {}, { hostToken, idempotencyKey })
}

export async function setGrid(
  hostToken: string,
  homeTeam: string,
  awayTeam: string,
  grid: GridConfig,
  idempotencyKey: string,
) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoSetGrid(homeTeam, awayTeam, grid))
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>(
    'set_grid',
    { homeTeam, awayTeam, rowDigits: grid.rowDigits, colDigits: grid.colDigits },
    { hostToken, idempotencyKey },
  )
}

export async function linkPurchase(
  hostToken: string,
  purchaseId: string,
  playerId: string | null,
  idempotencyKey: string,
) {
  return invoke<HostSnapshot>(
    'link_purchase',
    { purchaseId, playerId },
    { hostToken, idempotencyKey },
  )
}

export async function placeBet(playerToken: string, marketId: string, optionId: string, stake: number, idempotencyKey: string) {
  if (!backendConfigured) return demoPlaceBet(playerToken, marketId, optionId, stake, idempotencyKey)
  return invoke<PlayerSnapshot>('place_bet', { marketId, optionId, stake }, { playerToken, idempotencyKey })
}

export type MarketAction = 'lock_market' | 'settle_market' | 'void_market' | 'open_next_goal'
export async function marketAction(hostToken: string, action: MarketAction,
  payload: { marketId?: string; winningOptionId?: string; reason?: string }, idempotencyKey: string) {
  if (!backendConfigured) {
    demoMutation(idempotencyKey, () => demoMarketAction(action, payload))
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>(action, payload, { hostToken, idempotencyKey })
}
