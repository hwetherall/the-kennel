import type { HostSession, PlayerSession } from '../types'

const PLAYER_KEY = 'kennel.player-session.v1'
const HOST_KEY = 'kennel.host-session.v1'

function read<T>(storage: Storage, key: string): T | null {
  try {
    const value = storage.getItem(key)
    return value ? (JSON.parse(value) as T) : null
  } catch {
    return null
  }
}

export function getPlayerSession() {
  return read<PlayerSession>(localStorage, PLAYER_KEY)
}

export function savePlayerSession(session: PlayerSession) {
  localStorage.setItem(PLAYER_KEY, JSON.stringify(session))
}

export function clearPlayerSession() {
  localStorage.removeItem(PLAYER_KEY)
}

export function getHostSession() {
  const session = read<HostSession>(sessionStorage, HOST_KEY)
  if (session && new Date(session.expiresAt).getTime() > Date.now()) return session
  sessionStorage.removeItem(HOST_KEY)
  return null
}

export function saveHostSession(session: HostSession) {
  sessionStorage.setItem(HOST_KEY, JSON.stringify(session))
}

export function clearHostSession() {
  sessionStorage.removeItem(HOST_KEY)
}

export function newOpaqueToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32))
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
}

export function newIdempotencyKey() {
  return crypto.randomUUID()
}
