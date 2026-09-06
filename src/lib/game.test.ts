import { describe, expect, it } from 'vitest'
import type { GameState, GridConfig } from '../types'
import { liveSquareId, quarterLabel, scoreLine, shuffledDigits, winningSquareId } from './game'

const grid: GridConfig = {
  rowDigits: [7, 2, 9, 4, 0, 6, 1, 8, 3, 5],
  colDigits: [3, 8, 1, 6, 0, 5, 9, 2, 7, 4],
}

const game: GameState = {
  quarter: 2,
  periodStatus: 'live',
  homeGoals: 6,
  homeBehinds: 7,
  homePoints: 43,
  awayGoals: 5,
  awayBehinds: 6,
  awayPoints: 36,
  bettingPaused: false,
  version: 3,
  updatedAt: '2026-09-26T05:00:00Z',
  canUndo: true,
}

describe('squares game helpers', () => {
  it('formats an AFL scoreline', () => {
    expect(scoreLine(6, 7, 43)).toBe('6.7 (43)')
  })

  it('maps the last score digits through randomized headers', () => {
    expect(winningSquareId(43, 36, grid)).toBe(84)
    expect(liveSquareId(game, grid)).toBe(84)
  })

  it('labels live and break states clearly', () => {
    expect(quarterLabel(game)).toBe('Q2 live')
    expect(quarterLabel({ ...game, periodStatus: 'break' })).toBe('Quarter 2 siren')
  })

  it('always returns each digit once when shuffled', () => {
    const result = shuffledDigits(() => 0.25)
    expect(result).toHaveLength(10)
    expect([...result].sort()).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
  })
})
