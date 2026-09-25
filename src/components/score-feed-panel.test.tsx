import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { ScoreFeedPanel } from './score-feed-panel'
import { demoHostSnapshot, resetDemo } from '../lib/demo'
import type { HostSnapshot } from '../types'

afterEach(cleanup)
const now = '2026-09-26T05:10:30Z'

function snapshot(feed: Partial<NonNullable<HostSnapshot['scoreFeed']>>, game: Partial<HostSnapshot['game']> = {}): HostSnapshot {
  resetDemo()
  const base = demoHostSnapshot()
  return { ...base, serverNow: now, event: { ...base.event, homeTeam: 'Fremantle', awayTeam: 'Brisbane' },
    game: { ...base.game, periodStatus: 'live', homeGoals: 2, homeBehinds: 1, homePoints: 13, awayGoals: 1, awayBehinds: 3, awayPoints: 9, ...game },
    scoreFeed: { sourceGameId: 38729, homeGoals: 2, homeBehinds: 1, awayGoals: 1, awayBehinds: 3, timeLabel: 'Q1 14:02',
      complete: 12, receivedAt: '2026-09-26T05:10:20Z', ...feed } }
}

it('offers the score the feed has seen as a one-tap confirm', () => {
  const onConfirm = vi.fn()
  render(<ScoreFeedPanel snapshot={snapshot({ awayGoals: 2 })} disabled={false} onConfirm={onConfirm} />)
  fireEvent.click(screen.getByRole('button', { name: 'Confirm Brisbane goal' }))
  expect(onConfirm).toHaveBeenCalledWith('away', 'goal')
  expect(screen.getByText('Q1 14:02 · 10s ago')).toBeVisible()
})

it('shows nothing to confirm when the app matches, and warns when the app is ahead', () => {
  const view = render(<ScoreFeedPanel snapshot={snapshot({})} disabled={false} onConfirm={vi.fn()} />)
  expect(screen.getByText('The app matches the feed.')).toBeVisible()
  view.rerender(<ScoreFeedPanel snapshot={snapshot({ homeGoals: 1 })} disabled={false} onConfirm={vi.fn()} />)
  expect(screen.getByText(/The app has 1 more Fremantle goal than the feed/)).toBeVisible()
  expect(screen.queryByRole('button')).toBeNull()
})

it('flags a quiet feed and cannot confirm between quarters', () => {
  render(<ScoreFeedPanel snapshot={snapshot({ homeBehinds: 2, receivedAt: '2026-09-26T05:08:00Z' }, { periodStatus: 'break' })}
    disabled={false} onConfirm={vi.fn()} />)
  expect(screen.getByText(/has not reported for over a minute/)).toBeVisible()
  expect(screen.getByRole('button', { name: 'Confirm Fremantle behind' })).toBeDisabled()
})
