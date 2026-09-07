import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { PoolSplit } from './pool-split'
import { Ladder } from './ladder'
import { MarketCard, MarketSummaryCard } from './market-card'
import { demoHostSnapshot, demoMutation, demoPlaceBet, demoPlayerSnapshot, demoStartQuarter, resetDemo } from '../lib/demo'
import { newerSnapshot } from '../hooks/use-live-snapshot'
beforeEach(() => { resetDemo(); demoPlayerSnapshot('Alice:a'); demoMutation('start', () => demoStartQuarter(1)) })
afterEach(() => { cleanup(); vi.useRealTimers() })
it('renders empty, one-sided and two-sided pools in text', () => {
  let market = demoHostSnapshot().activeMarket!
  const { rerender } = render(<PoolSplit market={market} />)
  expect(screen.getAllByText('0 Bones · 0%')).toHaveLength(2)
  demoPlaceBet('Alice:a', market.id, market.options[0].id, 50, 'a')
  market = demoHostSnapshot().activeMarket!; rerender(<PoolSplit market={market} />)
  expect(screen.getByText('50 Bones · 100%')).toBeVisible()
  demoPlayerSnapshot('Bob:b'); demoPlaceBet('Bob:b', market.id, market.options[1].id, 50, 'b')
  rerender(<PoolSplit market={demoHostSnapshot().activeMarket!} />)
  expect(screen.getAllByText('50 Bones · 50%')).toHaveLength(2)
})
it('locks using elapsed server time even when the device wall clock is wrong', () => {
  vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval', 'performance'] })
  const market = demoHostSnapshot().activeMarket!
  render(<MarketSummaryCard market={market} serverNow={new Date(Date.parse(market.locksAt!) - 1000).toISOString()} />)
  expect(screen.getByText('Locks in 1s')).toBeVisible()
  act(() => vi.advanceTimersByTime(1500))
  expect(screen.getByText('Locked · awaiting next goal')).toBeVisible()
})
it('locks an existing selection and bounds stake suggestions by balance', () => {
  const market = demoHostSnapshot().activeMarket!
  demoPlaceBet('Alice:a', market.id, market.options[0].id, 1450, 'a')
  render(<MarketCard snapshot={demoPlayerSnapshot('Alice:a')} token="Alice:a" online reconcile={vi.fn()} refresh={vi.fn()} />)
  expect(screen.getByRole('button', { name: 'Away' })).toBeDisabled()
  expect(screen.getByRole('button', { name: '+100' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Max (50)' })).toBeEnabled()
})
it('shows signed profit and the guest row', () => {
  render(<Ladder title="Top Dog" entries={[{ rank: 1, playerId: 'a', nickname: 'Alice', profit: 100, isMe: true }]} />)
  expect(screen.getByText('+100')).toBeVisible(); expect(screen.getByText('Alice (you)')).toBeVisible()
})
it('rejects old mutation receipts and older same-version snapshots', () => {
  const current = demoHostSnapshot()
  const old = { ...current, game: { ...current.game, version: current.game.version - 1 }, serverNow: '2099-01-01T00:00:00Z' }
  expect(newerSnapshot(current, old)).toBe(current)
  expect(newerSnapshot(current, { ...current, serverNow: '2000-01-01T00:00:00Z' })).toBe(current)
})
