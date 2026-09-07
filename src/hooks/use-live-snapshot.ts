import { useCallback, useEffect, useState } from 'react'
import type { HostSnapshot, PlayerSnapshot, PublicSnapshot } from '../types'
import { backendConfigured, getHostSnapshot, getPlayerSnapshot, getPublicSnapshot, insforge } from '../lib/api'
import { subscribeDemo } from '../lib/demo'

const LIVE_EVENTS = ['score_updated', 'score_undone', 'quarter_updated', 'pause_updated', 'grid_updated']

function useNetworkStatus() {
  const [online, setOnline] = useState(() => navigator.onLine)

  useEffect(() => {
    const connected = () => setOnline(true)
    const disconnected = () => setOnline(false)
    window.addEventListener('online', connected)
    window.addEventListener('offline', disconnected)
    return () => {
      window.removeEventListener('online', connected)
      window.removeEventListener('offline', disconnected)
    }
  }, [])

  return online
}

export function useLiveSnapshot(playerToken?: string | null) {
  const [snapshot, setSnapshot] = useState<PublicSnapshot | PlayerSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const browserOnline = useNetworkStatus()
  const [realtimeOnline, setRealtimeOnline] = useState(true)

  const refresh = useCallback(async () => {
    try {
      const next = playerToken
        ? await getPlayerSnapshot(playerToken)
        : await getPublicSnapshot()
      setSnapshot(next)
      setError(null)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not load match state')
    } finally {
      setLoading(false)
    }
  }, [playerToken])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!backendConfigured) return subscribeDemo(() => void refresh())
    if (!insforge) {
      setRealtimeOnline(true)
      const interval = window.setInterval(() => void refresh(), 4_000)
      return () => window.clearInterval(interval)
    }
    const realtime = insforge.realtime

    let active = true
    const onChanged = () => void refresh()
    const onConnect = () => {
      if (!active) return
      setRealtimeOnline(true)
      void realtime.subscribe('game:live').then(() => refresh())
    }
    const onDisconnect = () => active && setRealtimeOnline(false)

    LIVE_EVENTS.forEach((event) => realtime.on(event, onChanged))
    realtime.on('connect', onConnect)
    realtime.on('disconnect', onDisconnect)
    realtime.on('connect_error', onDisconnect)
    void realtime.connect().then(() => realtime.subscribe('game:live')).then(() => {
      if (active) setRealtimeOnline(true)
    }).catch(() => {
      if (active) setRealtimeOnline(false)
    })

    return () => {
      active = false
      LIVE_EVENTS.forEach((event) => realtime.off(event, onChanged))
      realtime.off('connect', onConnect)
      realtime.off('disconnect', onDisconnect)
      realtime.off('connect_error', onDisconnect)
      realtime.unsubscribe('game:live')
    }
  }, [refresh])

  return {
    snapshot,
    loading,
    error,
    online: browserOnline && realtimeOnline,
    refresh,
  }
}

export function useLiveHostSnapshot(hostToken?: string | null) {
  const [snapshot, setSnapshot] = useState<HostSnapshot | null>(null)
  const [loading, setLoading] = useState(Boolean(hostToken))
  const [error, setError] = useState<string | null>(null)
  const browserOnline = useNetworkStatus()

  const refresh = useCallback(async () => {
    if (!hostToken) {
      setSnapshot(null)
      setLoading(false)
      return
    }
    try {
      setSnapshot(await getHostSnapshot(hostToken))
      setError(null)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not load host console')
    } finally {
      setLoading(false)
    }
  }, [hostToken])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!hostToken) return
    if (!backendConfigured) return subscribeDemo(() => void refresh())
    if (!insforge) {
      const interval = window.setInterval(() => void refresh(), 4_000)
      return () => window.clearInterval(interval)
    }
    const realtime = insforge.realtime
    const onChanged = () => void refresh()
    LIVE_EVENTS.forEach((event) => realtime.on(event, onChanged))
    return () => LIVE_EVENTS.forEach((event) => realtime.off(event, onChanged))
  }, [hostToken, refresh])

  return { snapshot, setSnapshot, loading, error, online: browserOnline, refresh }
}
