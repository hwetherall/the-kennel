import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
vi.mock('../lib/api', async (original) => ({ ...(await original<typeof import('../lib/api')>()), joinPlayer: vi.fn() }))
import { joinPlayer } from '../lib/api'
import { MarketCard } from './market-card'
import { JoinDialog } from '../pages/punter-page'
import { demoPlayerSnapshot, resetDemo } from '../lib/demo'
import type { MarketSummary, PlayerSnapshot } from '../types'

afterEach(() => { cleanup(); vi.clearAllMocks() })
beforeEach(() => resetDemo())

function market(overrides: Partial<MarketSummary> & Pick<MarketSummary, 'id' | 'type'>, labels: [string, string | null][]): MarketSummary {
  return {
    sequence: 1, quarter: null, title: 'Market', status: 'open', lockStrategy: 'bounce', opensAt: null, locksAt: null,
    settledAt: null, winningOptionId: null, maxStake: null, countsTowardQuarterPrize: true, sponsorLabel: null,
    voidReason: null, betCount: 0, totalPoolBones: 0, settlement: null, studs: null,
    options: labels.map(([label, teamLabel], index) => ({ id: `${overrides.id}-o${index}`, marketId: overrides.id,
      optionKey: `k${index}`, label, teamLabel, poolBones: 0, sortOrder: index, betCount: 0 })),
    ...overrides,
  }
}

const studs = market({ id: 's1', type: 'studs_v_spuds', quarter: 2, title: 'Shai Bolton v Zac Bailey',
  studs: { matchupId: 'm', slot: 1, roundLabel: 'Forwards Round', stat: 'disposals', baselineA: null, baselineB: null,
    endingA: null, endingB: null, quarterA: null, quarterB: null } }, [['Shai Bolton', 'FRE'], ['Zac Bailey', 'BRI']])
const norm = market({ id: 'n1', type: 'futures_norm_smith', title: 'Who wins the Norm Smith Medal?', maxStake: 200,
  countsTowardQuarterPrize: false }, [
  ['Will Ashcroft', 'BRI'], ['Luke Jackson', 'FRE'], ['Zac Bailey', 'BRI'], ['Caleb Serong', 'FRE'], ['Hugh McCluggage', 'BRI'],
  ['Andrew Brayshaw', 'FRE'], ['Dayne Zorko', 'BRI'], ['Shai Bolton', 'FRE'], ['Hayden Young', 'FRE'], ['Josh Dunkley', 'BRI'],
  ['Any other player', null]])

function breakSnapshot(): PlayerSnapshot {
  const snapshot = demoPlayerSnapshot('Alice:a')
  return { ...snapshot, game: { ...snapshot.game, periodStatus: 'break', quarter: 1 }, kennelMarkets: [norm, studs],
    positions: [{ id: 'p', marketId: 'n1', optionId: 'n1-o1', stake: 50, payout: null, profit: null, settledAt: null }] }
}
const props = { token: 'Alice:a', online: true, reconcile: vi.fn(), refresh: vi.fn() }

it('leads a break with the coming quarter’s Studs, locked by the bounce rather than a clock', () => {
  render(<MarketCard snapshot={breakSnapshot()} {...props} />)
  const headings = screen.getAllByRole('heading', { level: 2 }).map((h) => h.textContent)
  expect(headings.indexOf('Studs v Spuds')).toBeLessThan(headings.indexOf('No Next Goal market open'))
  expect(screen.getByText('Open · locks at the Q2 bounce')).toBeVisible()
  expect(screen.getByText('Most disposals in Q2 only')).toBeVisible()
  const card = screen.getByRole('heading', { name: 'Shai Bolton v Zac Bailey' }).closest('.market-card') as HTMLElement
  expect(within(card).getByRole('button', { name: 'Shai Bolton (FRE)' })).toBeEnabled()
})

it('keeps every Norm Smith candidate readable and caps the total stake at 200', () => {
  render(<MarketCard snapshot={breakSnapshot()} {...props} />)
  const card = screen.getByRole('heading', { name: 'Who wins the Norm Smith Medal?' }).closest('.market-card') as HTMLElement
  for (const option of norm.options) expect(within(card).getAllByText(option.label).length).toBeGreaterThan(0)
  expect(within(card).getByRole('button', { name: 'Luke Jackson (FRE) · Selected' })).toBeEnabled()
  expect(within(card).getByRole('button', { name: 'Any other player' })).toBeDisabled()
  // 50 already backed on Luke Jackson: only 150 more fits under the cap.
  expect(within(card).getByRole('button', { name: 'Max (150)' })).toBeEnabled()
  expect(within(card).getByText('Counts toward Top Dog only, not the quarter ladders.')).toBeVisible()
})

it('shows the quarter numbers once a Studs matchup settles', () => {
  const settled = { ...studs, status: 'settled' as const, settledAt: '2026-09-26T05:00:00Z', winningOptionId: 's1-o0',
    studs: { ...studs.studs!, baselineA: 10, baselineB: 12, endingA: 15, endingB: 16, quarterA: 5, quarterB: 4 } }
  render(<MarketCard snapshot={{ ...breakSnapshot(), kennelMarkets: [settled] }} {...props} />)
  fireEvent.click(screen.getByText('Studs v Spuds results'))
  expect(screen.getByText('This quarter: Shai Bolton 5 · Zac Bailey 4')).toBeVisible()
  expect(screen.getByText('Settled · Shai Bolton (FRE)')).toBeVisible()
})

it('joins by picking an unclaimed board name', async () => {
  vi.mocked(joinPlayer).mockResolvedValue({ player: { nickname: 'Taylor McHale' } } as PlayerSnapshot)
  const onJoined = vi.fn()
  render(<JoinDialog online onClose={vi.fn()} onJoined={onJoined} boardNames={[
    { purchaseId: 'p1', name: 'Taylor McHale', squaresCount: 5, claimed: false },
    { purchaseId: 'p2', name: 'Harry Wetherall', squaresCount: 2, claimed: true },
  ]} />)
  expect(screen.getByRole('option', { name: /Harry Wetherall/ })).toBeDisabled()
  fireEvent.change(screen.getByLabelText('Your name'), { target: { value: 'tay' } })
  expect(screen.queryByRole('option', { name: /Harry Wetherall/ })).toBeNull()
  fireEvent.click(screen.getByRole('option', { name: /Taylor McHale/ }))
  fireEvent.click(screen.getByRole('button', { name: 'Enter as Taylor McHale' }))
  await vi.waitFor(() => expect(onJoined).toHaveBeenCalledWith(expect.objectContaining({ nickname: 'Taylor McHale' })))
  expect(vi.mocked(joinPlayer).mock.calls[0][3]).toBe('p1')
})
