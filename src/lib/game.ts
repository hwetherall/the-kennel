import type { GameState, GridConfig } from '../types'

export function scoreLine(goals: number, behinds: number, points: number) {
  return `${goals}.${behinds} (${points})`
}

export function winningSquareId(
  homePoints: number,
  awayPoints: number,
  grid: GridConfig,
) {
  const rowIndex = grid.rowDigits.indexOf(Math.abs(homePoints) % 10)
  const colIndex = grid.colDigits.indexOf(Math.abs(awayPoints) % 10)

  if (rowIndex < 0 || colIndex < 0) return null
  return rowIndex * 10 + colIndex + 1
}

export function liveSquareId(game: GameState, grid: GridConfig) {
  return winningSquareId(game.homePoints, game.awayPoints, grid)
}

export function quarterLabel(game: GameState) {
  if (game.periodStatus === 'pre_match') return 'Pre-match'
  if (game.periodStatus === 'final') return 'Full time'
  if (game.periodStatus === 'break') return `Quarter ${game.quarter} siren`
  return `Q${game.quarter} live`
}

export function shuffledDigits(random = Math.random) {
  const digits = Array.from({ length: 10 }, (_, index) => index)
  for (let index = digits.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1))
    ;[digits[index], digits[swapIndex]] = [digits[swapIndex], digits[index]]
  }
  return digits
}
