import { useCallback, useEffect, useRef, useState } from 'react'
import type { HostSnapshot, PlayerSnapshot, PublicSnapshot } from '../types'
import { backendConfigured, getHostSnapshot, getPlayerSnapshot, getPublicSnapshot, insforge } from '../lib/api'
import { subscribeDemo } from '../lib/demo'

const LIVE_EVENTS = ['score_updated', 'score_undone', 'quarter_updated', 'pause_updated', 'grid_updated',
  'market_updated', 'bet_updated', 'balance_updated', 'ladder_updated']

export function newerSnapshot<T extends PublicSnapshot>(current: T | null, next: T): T {
  if (!current || next.game.version > current.game.version) return next
  if (next.game.version < current.game.version) return current
  return Date.parse(next.serverNow) >= Date.parse(current.serverNow) ? next : current
}

function useSnapshot<T extends PublicSnapshot>(identity: string, fetchSnapshot: () => Promise<T>, enabled = true) {
  const [snapshot, updateSnapshot] = useState<T | null>(null)
  const [loading, setLoading] = useState(enabled)
  const [error, setError] = useState<string | null>(null)
  const [online, setOnline] = useState(false)
  const currentIdentity = useRef(identity)
  currentIdentity.current = identity
  const networkEpoch = useRef(0)
  const latestRequest = useRef(0)
  const setSnapshot = useCallback((next: T) => {
    if (currentIdentity.current === identity) updateSnapshot((old) => newerSnapshot(old, next))
  }, [identity])
  const refresh = useCallback(async () => {
    if (!enabled) return
    const request = ++latestRequest.current
    const epoch = networkEpoch.current
    try {
      const next = await fetchSnapshot()
      if (currentIdentity.current !== identity || epoch !== networkEpoch.current) return
      setSnapshot(next)
      if (request === latestRequest.current) {
        setOnline(navigator.onLine)
        setError(null)
      }
    } catch (caught) {
      if (currentIdentity.current !== identity || request !== latestRequest.current) return
      setOnline(false)
      setError(caught instanceof Error ? caught.message : 'Could not load match state')
    } finally {
      if (currentIdentity.current === identity) setLoading(false)
    }
  }, [enabled, fetchSnapshot, identity, setSnapshot])

  useEffect(() => {
    updateSnapshot(null)
    setLoading(enabled)
    setOnline(false)
    setError(null)
    void refresh()
    const offline = () => { networkEpoch.current++; setOnline(false) }
    const reconnect = () => { offline(); void refresh() }
    window.addEventListener('offline', offline)
    window.addEventListener('online', reconnect)
    const visible = () => { if (document.visibilityState === 'visible') reconnect() }
    document.addEventListener('visibilitychange', visible)
    // Poll even with realtime: event delivery is an optimization, never a requirement.
    const interval = window.setInterval(() => { if (navigator.onLine) void refresh() }, 4_000)
    const unsubscribe = !backendConfigured ? subscribeDemo(() => void refresh()) : undefined
    const realtime = insforge?.realtime
    const changed = () => void refresh()
    const connect = () => { void realtime?.subscribe('game:live').then(refresh).catch(() => {}) }
    if (enabled && realtime) {
      LIVE_EVENTS.forEach((event) => realtime.on(event, changed))
      realtime.on('connect', connect)
      void realtime.connect().then(connect).catch(() => {})
    }
    return () => {
      networkEpoch.current++
      window.clearInterval(interval)
      window.removeEventListener('offline', offline)
      window.removeEventListener('online', reconnect)
      document.removeEventListener('visibilitychange', visible)
      unsubscribe?.()
      LIVE_EVENTS.forEach((event) => realtime?.off(event, changed))
      realtime?.off('connect', connect)
    }
  }, [enabled, refresh])
  return { snapshot, setSnapshot, loading, error, online, refresh }
}

export function useLiveSnapshot(playerToken?: string | null) {
  const fetchSnapshot = useCallback(() => playerToken ? getPlayerSnapshot(playerToken) : getPublicSnapshot(), [playerToken])
  return useSnapshot<PublicSnapshot | PlayerSnapshot>(playerToken ?? 'public', fetchSnapshot)
}

export function useLiveHostSnapshot(hostToken?: string | null) {
  const fetchSnapshot = useCallback(() => getHostSnapshot(hostToken!), [hostToken])
  return useSnapshot<HostSnapshot>(hostToken ?? 'host-locked', fetchSnapshot, Boolean(hostToken))
}
