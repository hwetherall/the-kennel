import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import type { GameState, GridConfig, Square } from '../types'
import { SquaresGrid } from './squares-grid'

const grid: GridConfig = {
  rowDigits: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  colDigits: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
}
const game: GameState = {
  quarter: 1,
  periodStatus: 'live',
  homeGoals: 1,
  homeBehinds: 1,
  homePoints: 7,
  awayGoals: 0,
  awayBehinds: 3,
  awayPoints: 3,
  bettingPaused: false,
  version: 1,
  updatedAt: '2026-09-26T04:45:00Z',
  canUndo: true,
}
const squares: Square[] = Array.from({ length: 100 }, (_, index) => ({
  id: index + 1,
  rowIndex: Math.floor(index / 10),
  colIndex: index % 10,
  ownerLabel: index === 73 ? 'Macca' : null,
}))

describe('SquaresGrid', () => {
  it('announces the currently live square and its owner', () => {
    render(
      <SquaresGrid
        game={game}
        grid={grid}
        squares={squares}
        homeTeam="Dogs"
        awayTeam="Cats"
        ownedSquareIds={[74]}
      />,
    )

    expect(screen.getByRole('gridcell', { name: /7-3: Macca, currently live/i })).toHaveClass('square--live', 'square--mine')
  })

  it('renders last-digit headers from 0 to 9 even when the assignment is shuffled', () => {
    const shuffled: GridConfig = {
      rowDigits: [7, 2, 9, 4, 0, 6, 1, 8, 3, 5],
      colDigits: [3, 8, 1, 6, 0, 5, 9, 2, 7, 4],
    }

    const { container } = render(
      <SquaresGrid
        game={game}
        grid={shuffled}
        squares={squares}
        homeTeam="Dogs"
        awayTeam="Cats"
      />,
    )

    expect(
      [...container.querySelectorAll('.digit-header:not(.digit-header--row)')].map((header) => header.textContent),
    ).toEqual(['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'])
    expect(
      [...container.querySelectorAll('.digit-header--row')].map((header) => header.textContent),
    ).toEqual(['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'])
    expect(screen.getByRole('gridcell', { name: /7-3: Open square, currently live/i })).toHaveClass('square--live')
  })
})
