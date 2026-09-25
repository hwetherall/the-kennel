// @vitest-environment node
import { readFileSync } from 'node:fs'
import { expect, it } from 'vitest'
// @ts-expect-error plain ESM script without type declarations
import { parseGridCsv, purchasesFromGrid } from '../../scripts/squares-grid.mjs'

const csv = readFileSync('AFL Grand Final - Squares Board - SQUARES.csv', 'utf8')
const identity = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

it('reads the real board: Fremantle down the side, Brisbane across the top, 100 owners', () => {
  const { homeTeam, awayTeam, cells } = parseGridCsv(csv)
  expect(homeTeam).toBe('FREMANTLE DOCKERS')
  expect(awayTeam).toBe('BRISBANE LIONS')
  expect(cells.flat()).toHaveLength(100)
  // Freo 7.3 (45) v Brisbane 12.6 (78): home 5, away 8.
  expect(cells[5][8]).toBe('Taylor McHale')
  expect(cells[2][4]).toBe('Russell Waugh, PHD')
})

it('makes one purchase per owner, capped squares intact, every square used once', () => {
  const purchases = purchasesFromGrid(parseGridCsv(csv).cells, identity, identity)
  expect(purchases).toHaveLength(34)
  expect(purchases.reduce((total: number, p: { squaresCount: number }) => total + p.squaresCount, 0)).toBe(100)
  expect(new Set(purchases.flatMap((p: { squareIds: number[] }) => p.squareIds)).size).toBe(100)
  expect(purchases.find((p: { purchaserName: string }) => p.purchaserName === 'Harry Wetherall'))
    .toMatchObject({ squaresCount: 2, squareIds: [80, 96], purchaserEmail: '' })
})

it('places names by printed digit under a shuffled digit order', () => {
  const rows = [7, 2, 9, 4, 0, 6, 1, 8, 3, 5]
  const cols = [3, 8, 1, 6, 0, 5, 9, 2, 7, 4]
  const purchases = purchasesFromGrid(parseGridCsv(csv).cells, rows, cols)
  const taylor = purchases.find((p: { purchaserName: string }) => p.purchaserName === 'Taylor McHale')
  // Home 5 sits at row index 9, away 8 at column index 1: square 92.
  expect(taylor.squareIds).toContain(rows.indexOf(5) * 10 + cols.indexOf(8) + 1)
})
