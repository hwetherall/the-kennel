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

export const backendConfigured = !demoMode && Boolean(baseUrl && anonKey)

export const insforge = backendConfigured
  ? createClient({ baseUrl: baseUrl!, anonKey: anonKey! })
  : null

interface InvokeOptions {
  playerToken?: string
  hostToken?: string
  idempotencyKey?: string
}

async function invoke<T>(action: string, payload = {}, options: InvokeOptions = {}) {
  if (!insforge) throw new Error('Backend is not configured')

  const headers: Record<string, string> = {}
  if (options.playerToken) headers['X-Player-Token'] = options.playerToken
  if (options.hostToken) headers['X-Host-Token'] = options.hostToken
  if (options.idempotencyKey) headers['Idempotency-Key'] = options.idempotencyKey

  const { data, error } = await insforge.functions.invoke('kennel-api', {
    body: { action, ...payload },
    headers,
  })

  if (error) throw new Error(error.message || 'The Kennel could not reach the server')
  const response = data as { data?: T; error?: string } | T
  if (response && typeof response === 'object' && 'error' in response && response.error) {
    throw new Error(response.error)
  }
  if (response && typeof response === 'object' && 'data' in response) {
    return response.data as T
  }
  return response as T
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
  if (!backendConfigured) return demoPlayerSnapshot(`${nickname}:${sessionToken}`)
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
    demoRecordScore(team, scoreType)
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('record_score', { team, scoreType }, { hostToken, idempotencyKey })
}

export async function undoLatestScore(hostToken: string, idempotencyKey: string) {
  if (!backendConfigured) {
    demoUndo()
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('undo_latest_score', {}, { hostToken, idempotencyKey })
}

export async function setPause(hostToken: string, paused: boolean, idempotencyKey: string) {
  if (!backendConfigured) {
    demoPause(paused)
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('set_pause', { paused }, { hostToken, idempotencyKey })
}

export async function startQuarter(hostToken: string, quarter: number, idempotencyKey: string) {
  if (!backendConfigured) {
    demoStartQuarter(quarter)
    return demoHostSnapshot()
  }
  return invoke<HostSnapshot>('start_quarter', { quarter }, { hostToken, idempotencyKey })
}

export async function endQuarter(hostToken: string, idempotencyKey: string) {
  if (!backendConfigured) {
    demoEndQuarter()
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
    demoSetGrid(homeTeam, awayTeam, grid)
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
