import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { HostFutures, HostStuds } from './host-kennel'
import { demoHostSnapshot, resetDemo } from '../lib/demo'
import type { HostSnapshot, StudsMatchup } from '../types'

afterEach(cleanup)

const matchup: StudsMatchup = {
  id: 'm2', quarter: 2, slot: 1, roundLabel: 'Forwards Round', stat: 'disposals',
  athleteAId: 'a', athleteAName: 'Shai Bolton', athleteATeam: 'FRE',
  athleteBId: 'b', athleteBName: 'Zac Bailey', athleteBTeam: 'BRI',
  baselineA: 10, baselineB: 12, endingA: null, endingB: null, marketId: 'mk', marketStatus: 'locked', resolvedAt: null,
}

function snapshot(overrides: Partial<HostSnapshot> = {}): HostSnapshot {
  resetDemo()
  const base = demoHostSnapshot()
  return { ...base, game: { ...base.game, periodStatus: 'break', quarter: 2 },
    quarterResults: [1, 2].map((quarter) => ({ quarter, homePoints: 0, awayPoints: 0, winningSquareId: 1, winnerLabel: null,
      settledAt: '2026-09-26T05:00:00Z', ladderFinalizedAt: quarter === 2 ? null : '2026-09-26T05:00:00Z', quarterLadder: [] })),
    studsMatchups: [matchup], ...overrides }
}

it('previews the quarter delta from cumulative totals and sends only the totals', () => {
  const onAction = vi.fn()
  render(<HostStuds snapshot={snapshot()} disabled={false} onAction={onAction} />)
  const [endingA, endingB] = screen.getAllByLabelText(/Shai Bolton|Zac Bailey/).slice(2)
  fireEvent.change(endingA, { target: { value: '15' } })
  fireEvent.change(endingB, { target: { value: '16' } })
  expect(screen.getByText(/This quarter: Shai Bolton 5 · Zac Bailey 4\. Shai Bolton wins the quarter, 5 to 4\./)).toBeVisible()
  fireEvent.click(screen.getByRole('button', { name: 'Review result' }))
  fireEvent.click(screen.getByRole('button', { name: 'Confirm result' }))
  expect(onAction).toHaveBeenCalledWith('settle studs', 'settle_studs', { matchupId: 'm2', endingA: 15, endingB: 16 })
})

it('refuses a total below its baseline and calls a level quarter a refund', () => {
  render(<HostStuds snapshot={snapshot()} disabled={false} onAction={vi.fn()} />)
  const [endingA, endingB] = screen.getAllByLabelText(/Shai Bolton|Zac Bailey/).slice(2)
  fireEvent.change(endingA, { target: { value: '9' } })
  fireEvent.change(endingB, { target: { value: '16' } })
  expect(screen.getByText('A cumulative total cannot be lower than its baseline.')).toBeVisible()
  expect(screen.getByRole('button', { name: 'Review result' })).toBeDisabled()
  fireEvent.change(endingA, { target: { value: '14' } })
  expect(screen.getByText(/Level at 4 each: every stake is refunded\./)).toBeVisible()
})

it('offers to open the next quarter’s unopened matchups during a break', () => {
  const onAction = vi.fn()
  const q3 = { ...matchup, id: 'm3', quarter: 3, marketId: null, marketStatus: null, baselineA: null, baselineB: null }
  render(<HostStuds snapshot={snapshot({ studsMatchups: [matchup, q3] })} disabled={false} onAction={onAction} />)
  fireEvent.click(screen.getByRole('button', { name: 'Open Q3 Studs (1)' }))
  expect(onAction).toHaveBeenCalledWith('open studs', 'open_studs', {})
})

it('derives the match winner from the final score before confirming', () => {
  const onAction = vi.fn()
  const base = snapshot()
  const winner = { ...base.activeMarket, id: 'w', type: 'futures_winner', title: 'Who wins the match?', status: 'locked',
    lockStrategy: 'bounce', quarter: null, locksAt: null, opensAt: null, settledAt: null, winningOptionId: null, maxStake: 200,
    countsTowardQuarterPrize: false, sponsorLabel: null, voidReason: null, betCount: 0, totalPoolBones: 0, settlement: null,
    sequence: 1, options: [], studs: null } as HostSnapshot['futures'][number]
  render(<HostFutures snapshot={{ ...base, game: { ...base.game, periodStatus: 'final', homePoints: 81, awayPoints: 77 },
    event: { ...base.event, homeTeam: 'Fremantle', awayTeam: 'Brisbane' }, futures: [winner] }} disabled={false} onAction={onAction} />)
  fireEvent.click(screen.getByRole('button', { name: 'Settle match winner from the final score' }))
  expect(screen.getByText('Final score 81–77: pay Fremantle backers.')).toBeVisible()
  fireEvent.click(screen.getByRole('button', { name: 'Confirm' }))
  expect(onAction).toHaveBeenCalledWith('settle match winner', 'settle_match_future', {})
})
