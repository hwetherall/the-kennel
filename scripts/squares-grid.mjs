// Reads the club's already-drawn squares board: a CSV laid out like the paper
// board, home-team digits down the side and away-team digits across the top.
import { parse } from 'csv-parse/sync'

const DIGITS = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']

/** Returns cells[homeDigit][awayDigit] = owner name, plus the two team labels. */
export function parseGridCsv(text) {
  const rows = parse(text, { relax_column_count: true, bom: true })
  const headerIndex = rows.findIndex((row) => DIGITS.every((digit, index) => String(row[index + 2] ?? '').trim() === digit))
  if (headerIndex < 0) throw new Error('Could not find the 0-9 away-team digit header row')
  const awayTeam = String(rows[headerIndex - 1]?.[2] ?? '').trim()
  const homeTeam = String(rows[headerIndex + 1]?.[0] ?? '').trim()

  const cells = []
  for (let digit = 0; digit < 10; digit += 1) {
    const row = rows[headerIndex + 1 + digit]
    if (String(row?.[1] ?? '').trim() !== String(digit)) {
      throw new Error(`Expected home-team digit ${digit} on board row ${digit + 1}`)
    }
    const names = row.slice(2, 12).map((name) => String(name ?? '').trim())
    const blank = names.findIndex((name) => !name)
    if (blank >= 0) throw new Error(`Square at home ${digit}, away ${blank} has no owner`)
    cells.push(names)
  }
  return { homeTeam, awayTeam, cells }
}

/**
 * One purchase per owner, with the square IDs that sit at their printed digits
 * under the app's digit order. The app renders headers 0-9 and resolves cells by
 * digit, so this places every name where the paper board has it.
 */
export function purchasesFromGrid(cells, rowDigits, colDigits) {
  const byName = new Map()
  cells.forEach((names, homeDigit) => names.forEach((name, awayDigit) => {
    const rowIndex = rowDigits.indexOf(homeDigit)
    const colIndex = colDigits.indexOf(awayDigit)
    if (rowIndex < 0 || colIndex < 0) throw new Error('Grid digits must contain 0 through 9')
    const key = name.toLowerCase()
    const purchase = byName.get(key) ?? { purchaserName: name, squareIds: [] }
    purchase.squareIds.push(rowIndex * 10 + colIndex + 1)
    byName.set(key, purchase)
  }))
  return [...byName.values()]
    .sort((left, right) => left.purchaserName.localeCompare(right.purchaserName))
    .map((purchase, index) => ({
      sourceRef: `board-${index + 1}`,
      purchaserName: purchase.purchaserName,
      purchaserEmail: '',
      squaresCount: purchase.squareIds.length,
      squareIds: purchase.squareIds.sort((left, right) => left - right),
    }))
}
