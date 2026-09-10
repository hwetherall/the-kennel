import { act, cleanup, renderHook, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { PlayerSnapshot } from '../types'
vi.mock('../lib/api', () => ({ backendConfigured: true, insforge: null,
  getPlayerSnapshot: vi.fn(), getPublicSnapshot: vi.fn(), getHostSnapshot: vi.fn() }))
import { getPlayerSnapshot } from '../lib/api'
import { useLiveSnapshot } from './use-live-snapshot'
import { demoPlayerSnapshot } from '../lib/demo'
afterEach(() => { cleanup(); vi.clearAllMocks() })
function deferred() {
  let resolve!: (value: PlayerSnapshot) => void
  const promise = new Promise<PlayerSnapshot>((done) => { resolve = done })
  return { promise, resolve }
}
it('rejects an in-flight response from the previous guest', async () => {
  const first = deferred(); const second = deferred()
  vi.mocked(getPlayerSnapshot).mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise)
  const hook = renderHook(({ token }) => useLiveSnapshot(token), { initialProps: { token: 'old' } })
  hook.rerender({ token: 'new' })
  const current = demoPlayerSnapshot('New:new')
  await act(async () => second.resolve(current))
  await act(async () => first.resolve(demoPlayerSnapshot('Old:old')))
  expect(hook.result.current.snapshot).toEqual(current)
})
it('reconciles on reconnect before controls become online', async () => {
  const snapshot = demoPlayerSnapshot('Alice:a')
  vi.mocked(getPlayerSnapshot).mockResolvedValueOnce(snapshot)
  const hook = renderHook(() => useLiveSnapshot('a'))
  await waitFor(() => expect(hook.result.current.online).toBe(true))
  act(() => window.dispatchEvent(new Event('offline')))
  expect(hook.result.current.online).toBe(false)
  const reconnect = deferred(); vi.mocked(getPlayerSnapshot).mockReturnValueOnce(reconnect.promise)
  act(() => window.dispatchEvent(new Event('online')))
  expect(hook.result.current.online).toBe(false)
  await act(async () => reconnect.resolve(snapshot))
  expect(hook.result.current.online).toBe(true)
})
