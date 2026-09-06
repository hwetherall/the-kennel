import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { basename, resolve } from 'node:path'
import { createAdminClient } from '@insforge/sdk'
import { parse } from 'csv-parse/sync'

const fileArgument = process.argv[2]
if (!fileArgument) {
  console.error('Usage: npm run import:squares -- path/to/zeffy-export.csv')
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
const checksum = createHash('sha256').update(file).digest('hex')
const records = parse(file, {
  columns: true,
  skip_empty_lines: true,
  trim: true,
  bom: true,
})

function normalizedRecord(record) {
  return Object.fromEntries(
    Object.entries(record).map(([key, value]) => [key.toLowerCase().replace(/[^a-z0-9]/g, ''), value]),
  )
}

function first(row, candidates) {
  for (const candidate of candidates) {
    if (row[candidate] !== undefined && String(row[candidate]).trim()) return String(row[candidate]).trim()
  }
  return ''
}

const purchases = records.map((record, index) => {
  const row = normalizedRecord(record)
  const purchaserName = first(row, ['purchasername', 'fullname', 'name', 'firstandlastname'])
    || [first(row, ['firstname']), first(row, ['lastname'])].filter(Boolean).join(' ')
  const purchaserEmail = first(row, ['purchaseremail', 'email', 'emailaddress']).toLowerCase()
  const rawCount = first(row, ['squarescount', 'quantity', 'ticketquantity', 'numberoftickets'])
  const squaresCount = Number.parseInt(rawCount, 10)

  if (!purchaserName || !purchaserEmail || !Number.isInteger(squaresCount) || squaresCount < 1) {
    const headers = Object.keys(record).join(', ')
    throw new Error(`Could not read name, email, and square quantity on CSV row ${index + 2}. Headers: ${headers}`)
  }

  return {
    sourceRef: `row-${index + 2}`,
    purchaserName,
    purchaserEmail,
    squaresCount,
    squareIds: [],
  }
})

const totalSquares = purchases.reduce((total, purchase) => total + purchase.squaresCount, 0)
if (totalSquares > 100) throw new Error(`The CSV asks for ${totalSquares} squares; only 100 exist`)

function seedHash(value) {
  let hash = 2166136261
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return hash >>> 0
}

function mulberry32(seed) {
  return () => {
    let next = seed += 0x6d2b79f5
    next = Math.imul(next ^ next >>> 15, next | 1)
    next ^= next + Math.imul(next ^ next >>> 7, next | 61)
    return ((next ^ next >>> 14) >>> 0) / 4294967296
  }
}

const seed = `${process.env.SQUARES_SEED ?? 'denver-bulldogs-2026'}:${checksum}`
const random = mulberry32(seedHash(seed))
const squareIds = Array.from({ length: 100 }, (_, index) => index + 1)
for (let index = squareIds.length - 1; index > 0; index -= 1) {
  const swapIndex = Math.floor(random() * (index + 1))
  ;[squareIds[index], squareIds[swapIndex]] = [squareIds[swapIndex], squareIds[index]]
}

let cursor = 0
for (const purchase of purchases) {
  purchase.squareIds = squareIds.slice(cursor, cursor + purchase.squaresCount)
  cursor += purchase.squaresCount
}

const backend = createAdminClient({ baseUrl, apiKey })
const { data, error } = await backend.database.rpc('kennel_import_square_purchases', {
  p_checksum: checksum,
  p_source_name: basename(filePath),
  p_rows: purchases,
})

if (error) throw new Error(error.message || 'Squares import failed')

console.log(JSON.stringify({ ...data, totalSquares, seed }, null, 2))
