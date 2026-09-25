// Imports the already-drawn squares board CSV. Unlike import-squares.mjs this
// assigns nothing at random: every owner lands on the square the paper board
// shows. Repeat imports of the same file are no-ops.
//
//   npm run import:grid -- "AFL Grand Final - Squares Board - SQUARES.csv"
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { basename, resolve } from 'node:path'
import { createAdminClient } from '@insforge/sdk'
import { parseGridCsv, purchasesFromGrid } from './squares-grid.mjs'

const fileArgument = process.argv[2]
if (!fileArgument) {
  console.error('Usage: npm run import:grid -- path/to/squares-board.csv')
  process.exit(1)
}
const baseUrl = process.env.INSFORGE_URL
const apiKey = process.env.INSFORGE_API_KEY
if (!baseUrl || !apiKey) {
  console.error('INSFORGE_URL and INSFORGE_API_KEY are required in .env.local')
  process.exit(1)
}

const filePath = resolve(fileArgument)
const file = await readFile(filePath)
const { homeTeam, awayTeam, cells } = parseGridCsv(file.toString('utf8'))
const backend = createAdminClient({ baseUrl, apiKey })

const { data: snapshot, error: snapshotError } = await backend.database.rpc('kennel_public_snapshot', {})
if (snapshotError) throw new Error(snapshotError.message || 'Could not read the board')

// Swapped teams would transpose the whole board, so refuse rather than guess.
const firstWord = (label) => label.split(/\s+/)[0].toLowerCase()
if (!snapshot.event.homeTeam.toLowerCase().includes(firstWord(homeTeam))
  || !snapshot.event.awayTeam.toLowerCase().includes(firstWord(awayTeam))) {
  console.error(`The CSV has ${homeTeam} down the side (home) and ${awayTeam} across the top (away),`)
  console.error(`but the app has home "${snapshot.event.homeTeam}" and away "${snapshot.event.awayTeam}".`)
  console.error('Set the teams in the host console first.')
  process.exit(1)
}

const purchases = purchasesFromGrid(cells, snapshot.grid.rowDigits, snapshot.grid.colDigits)
const { data, error } = await backend.database.rpc('kennel_import_square_purchases', {
  p_checksum: createHash('sha256').update(file).digest('hex'),
  p_source_name: basename(filePath),
  p_rows: purchases,
})
if (error) throw new Error(error.message || 'Squares import failed')

// Read the board back and compare every square with the CSV.
const { data: after } = await backend.database.rpc('kennel_public_snapshot', {})
const owners = new Map(after.squares.map((square) => [square.id, square.ownerLabel]))
const mismatches = []
cells.forEach((names, homeDigit) => names.forEach((name, awayDigit) => {
  const id = after.grid.rowDigits.indexOf(homeDigit) * 10 + after.grid.colDigits.indexOf(awayDigit) + 1
  if (owners.get(id) !== name) mismatches.push(`${homeTeam} ${homeDigit} / ${awayTeam} ${awayDigit}: CSV ${name}, app ${owners.get(id)}`)
}))

console.log(JSON.stringify({ ...data, owners: purchases.length }, null, 2))
if (mismatches.length) {
  console.error(`${mismatches.length} squares differ from the CSV (a player may have claimed a name):`)
  mismatches.forEach((line) => console.error(`  ${line}`))
  process.exit(1)
}
console.log('All 100 squares match the CSV.')
