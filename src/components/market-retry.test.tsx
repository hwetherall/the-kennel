import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
vi.mock('../lib/api', () => ({ placeBet: vi.fn(), ApiError: class extends Error { uncertain = true } }))
import { placeBet } from '../lib/api'
import { MarketCard } from './market-card'
import { demoMutation, demoPlayerSnapshot, demoStartQuarter, resetDemo } from '../lib/demo'
afterEach(() => { cleanup(); sessionStorage.clear(); vi.clearAllMocks() })
it('retains an uncertain intent across a remount and retries with its original key', async () => {
  resetDemo(); const token = 'Alice:retry'; demoPlayerSnapshot(token); demoMutation('start', () => demoStartQuarter(1))
  const snapshot = demoPlayerSnapshot(token)
  vi.mocked(placeBet).mockRejectedValueOnce(new Error('Response lost')).mockResolvedValueOnce(snapshot)
  const props = { snapshot, token, online: true, reconcile: vi.fn(), refresh: vi.fn().mockResolvedValue(undefined) }
  const view = render(<MarketCard {...props} />)
  fireEvent.click(screen.getByRole('button', { name: 'Home' }))
  fireEvent.click(screen.getByRole('button', { name: '+50' }))
  await screen.findByText('Response lost')
  expect(screen.getByRole('button', { name: '+25' })).toBeDisabled()
  const original = vi.mocked(placeBet).mock.calls[0]
  view.unmount()
  render(<MarketCard {...props} />)
  fireEvent.click(screen.getByRole('button', { name: 'Retry original request' }))
  await waitFor(() => expect(placeBet).toHaveBeenCalledTimes(2))
  expect(vi.mocked(placeBet).mock.calls[1]).toEqual(original)
  await screen.findByText('Stake accepted. Your selection is fixed for this market.')
})
