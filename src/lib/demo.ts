import type {
  GridConfig,
  HostSnapshot,
  PlayerSnapshot,
  PublicSnapshot,
  ScoreType,
  TeamSide,
  MarketSummary, PlayerMarketPosition, PlayerSummary, LedgerEntry, LadderEntry,
} from '../types'
import { winningSquareId } from './game'
import { settleReferenceMarket } from './settlement'

const grid: GridConfig = {
  rowDigits: [7, 2, 9, 4, 0, 6, 1, 8, 3, 5],
  colDigits: [3, 8, 1, 6, 0, 5, 9, 2, 7, 4],
}

let state: PublicSnapshot = {
  serverNow: new Date().toISOString(),
  event: {
    eventName: 'Denver Bulldogs Grand Final Night',
    eventCode: 'DOGS26',
    venue: '1111 Lincoln St, Denver',
    startsAt: '2026-09-26T04:30:00.000Z',
    timezone: 'America/Denver',
    homeTeam: 'Home',
    awayTeam: 'Away',
    zeffyUrl: import.meta.env.VITE_ZEFFY_URL ?? null,
  },
  game: {
    quarter: 1,
    periodStatus: 'pre_match',
    homeGoals: 0,
    homeBehinds: 0,
    homePoints: 0,
    awayGoals: 0,
    awayBehinds: 0,
    awayPoints: 0,
    bettingPaused: false,
    version: 1,
    updatedAt: new Date().toISOString(),
    canUndo: false,
  },
  grid,
  squares: Array.from({ length: 100 }, (_, index) => ({
    id: index + 1,
    rowIndex: Math.floor(index / 10),
    colIndex: index % 10,
    ownerLabel:
      index % 13 === 0
        ? ['Harry', 'Macca', 'Sarah', 'Jonesy'][index % 4]
        : index % 7 === 0
          ? `Dog ${index + 1}`
          : null,
  })),
  quarterResults: [],
  activeMarket: null,
  recentMarket: null,
  quarterLadder: [],
  topDogLadder: [],
}

// Synthetic, local-only simulator. Production always uses the edge API.
type DemoBet = PlayerMarketPosition & { playerId: string }
type DemoScore = { game: PublicSnapshot['game']; settledId?: string; openedSequence?: number }
const storageKey = 'kennel-demo-phase-two-v2'
const initialState = structuredClone(state)
let markets: MarketSummary[] = []
let players: Record<string, PlayerSummary> = {}
let bets: DemoBet[] = []
let activity: Record<string, LedgerEntry[]> = {}
let scores: DemoScore[] = []
let receipts: string[] = []
const listeners = new Set<() => void>()
const now = () => new Date().toISOString()
function restore() {
  const saved = localStorage.getItem(storageKey)
  if (!saved) return
  try { ({ state, markets, players, bets, activity, scores, receipts } = JSON.parse(saved)) } catch { /* start fresh */ }
}
restore()
window.addEventListener('storage', (event) => {
  if (event.key === storageKey) { restore(); listeners.forEach((listener) => listener()) }
})
function emit() {
  state.game.version++
  state.game.updatedAt = now()
  localStorage.setItem(storageKey, JSON.stringify({ state, markets, players, bets, activity, scores, receipts }))
  listeners.forEach((listener) => listener())
}
export function resetDemo() {
  state = structuredClone(initialState)
  markets = []; players = {}; bets = []; activity = {}; scores = []; receipts = []
  emit()
}
export function demoMutation(key: string, action: () => void) {
  restore()
  if (receipts.includes(key)) return
  action()
  receipts.push(key)
  emit()
}
export function subscribeDemo(listener: () => void) {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}
function ladder(quarter?: number, me?: string): LadderEntry[] {
  return Object.values(players).map((player) => ({ playerId: player.id, nickname: player.nickname,
    profit: bets.filter((bet) => bet.playerId === player.id && bet.settledAt && (!quarter || markets.find((m) => m.id === bet.marketId)?.quarter === quarter))
      .reduce((sum, bet) => sum + (bet.profit ?? 0), 0), isMe: player.id === me, rank: 0,
  })).sort((a, b) => b.profit - a.profit || a.nickname.toLowerCase().localeCompare(b.nickname.toLowerCase()))
    .map((entry, index) => ({ ...entry, rank: index + 1 }))
}
function effective(market: MarketSummary): MarketSummary {
  return { ...market, status: market.status === 'open' && Date.now() >= Date.parse(market.locksAt!) ? 'locked' : market.status }
}
export function demoPublicSnapshot(): PublicSnapshot {
  return structuredClone({ ...state, serverNow: now(),
    activeMarket: markets.filter((m) => !m.settledAt).map(effective).at(-1) ?? null,
    recentMarket: markets.filter((m) => m.settledAt).at(-1) ?? null,
    quarterLadder: ladder(state.game.quarter).slice(0, 5), topDogLadder: ladder().slice(0, 5),
  })
}
function credit(playerId: string, amount: number, kind: LedgerEntry['kind'], marketId: string | null = null, reversalOfId: string | null = null) {
  if (!amount) return
  const player = Object.values(players).find((p) => p.id === playerId)!
  player.balance += amount
  if (player.balance < 0) throw new Error('Not enough Bones')
  ;(activity[playerId] ??= []).unshift({ id: crypto.randomUUID(), kind, amount, marketId, reversalOfId, balanceAfter: player.balance, createdAt: now() })
}
export function demoPlayerSnapshot(token: string): PlayerSnapshot {
  if (!players[token]) {
    players[token] = { id: crypto.randomUUID(), nickname: token.includes(':') ? token.split(':')[0] : 'Guest',
      squaresCount: 2, isSquareHolder: true, balance: 0 }
    credit(players[token].id, 1000, 'courtesy_grant')
    credit(players[token].id, 500, 'square_bonus')
    emit()
  }
  const player = players[token]
  const snapshot = demoPublicSnapshot()
  const quarterLadder = ladder(state.game.quarter, player.id)
  const topDogLadder = ladder(undefined, player.id)
  return structuredClone({ ...snapshot, quarterLadder, topDogLadder,
    player: { ...player, quarterRank: quarterLadder.find((p) => p.isMe)?.rank ?? null, topDogRank: topDogLadder.find((p) => p.isMe)?.rank ?? null },
    ownedSquareIds: [1, 53], activeBet: bets.find((b) => b.playerId === player.id && b.marketId === snapshot.activeMarket?.id) ?? null,
    recentActivity: activity[player.id].slice(0, 20),
  })
}
export function demoHostSnapshot(): HostSnapshot {
  return structuredClone({ ...demoPublicSnapshot(), markets: markets.slice().reverse().map(effective),
    players: Object.values(players), purchases: [], quarterLadder: ladder(state.game.quarter), topDogLadder: ladder() })
}
function openMarket() {
  if (state.game.periodStatus !== 'live') throw new Error('Start a quarter before opening a market')
  if (markets.some((m) => !m.settledAt)) return
  const id = crypto.randomUUID()
  markets.push({ id, sequence: markets.length + 1, type: 'next_goal', quarter: state.game.quarter,
    title: 'Which team scores the next goal?', status: 'open', opensAt: now(), locksAt: new Date(Date.now() + 90_000).toISOString(),
    settledAt: null, winningOptionId: null, maxStake: null, countsTowardQuarterPrize: true, sponsorLabel: null,
    voidReason: null, betCount: 0, totalPoolBones: 0, settlement: null,
    options: (['home', 'away'] as const).map((side, index) => ({ id: crypto.randomUUID(), marketId: id, optionKey: side,
      label: side === 'home' ? state.event.homeTeam : state.event.awayTeam, poolBones: 0, sortOrder: index, betCount: 0 })),
  })
}
export function demoPlaceBet(token: string, marketId: string, optionId: string, stake: number, key: string) {
  demoMutation(`${token}:${key}`, () => {
    const player = players[token]
    const market = markets.find((m) => m.id === marketId)
    if (!player) throw new Error('Player session is no longer valid')
    if (!market || effective(market).status !== 'open') throw new Error('Market has locked')
    if (state.game.bettingPaused) throw new Error('Betting is paused')
    const option = market.options.find((o) => o.id === optionId)
    if (!option) throw new Error('Unknown option')
    const bet = bets.find((b) => b.playerId === player.id && b.marketId === marketId)
    if (bet && bet.optionId !== optionId) throw new Error('Your existing selection cannot be changed')
    if (!Number.isInteger(stake) || stake <= 0) throw new Error('Stake must be positive')
    if (stake > player.balance) throw new Error('Not enough Bones')
    if (market.maxStake && (bet?.stake ?? 0) + stake > market.maxStake) throw new Error('Market cap reached')
    if (bet) bet.stake += stake
    else { bets.push({ id: crypto.randomUUID(), playerId: player.id, marketId, optionId, stake, payout: null, profit: null, settledAt: null }); market.betCount++; option.betCount++ }
    option.poolBones += stake; market.totalPoolBones += stake
    credit(player.id, -stake, 'stake', marketId)
  })
  return demoPlayerSnapshot(token)
}
function finish(market: MarketSummary, winner?: string, reason = 'Host voided this market') {
  if (market.settledAt) return
  const positions = bets.filter((b) => b.marketId === market.id)
  const settledAt = now()
  const result = winner ? settleReferenceMarket({ optionIds: market.options.map((o) => o.id), bets: positions, settlement: null }, winner, settledAt).market.settlement! : null
  const voided = !result || result.status === 'void'
  market.status = voided ? 'void' : 'settled'; market.settledAt = settledAt
  market.winningOptionId = voided ? null : winner!
  market.voidReason = voided ? (winner ? 'No Bones backed the winner' : reason) : null
  market.settlement = { winningPoolBones: result?.winningPoolBones ?? 0, losingPoolBones: result?.losingPoolBones ?? market.totalPoolBones, dustBones: result?.dustBones ?? 0 }
  positions.forEach((bet) => {
    bet.payout = voided ? bet.stake : result!.bets.find((b) => b.id === bet.id)!.payout
    bet.profit = bet.payout - bet.stake; bet.settledAt = settledAt
    credit(bet.playerId, bet.payout, voided ? 'refund' : 'payout', market.id)
  })
}
function reverse(market: MarketSummary) {
  for (const rows of Object.values(activity)) {
    const reversed = new Set(rows.map((row) => row.reversalOfId))
    for (const row of rows.slice()) {
      if (row.marketId === market.id && row.amount > 0 && !row.reversalOfId && !reversed.has(row.id)) {
        const playerId = Object.keys(activity).find((id) => activity[id] === rows)!
        credit(playerId, -row.amount, row.kind, market.id, row.id)
      }
    }
  }
  market.status = 'locked'; market.settledAt = null; market.winningOptionId = null; market.voidReason = null; market.settlement = null
  bets.filter((b) => b.marketId === market.id).forEach((b) => { b.payout = null; b.profit = null; b.settledAt = null })
}
export function demoMarketAction(action: string, payload: { marketId?: string; winningOptionId?: string; reason?: string }) {
  if (action === 'open_next_goal') { openMarket(); return }
  const market = markets.find((m) => m.id === payload.marketId)
  if (!market) throw new Error('Market not found')
  if (action === 'lock_market' && !market.settledAt) market.status = 'locked'
  if (action === 'settle_market') finish(market, payload.winningOptionId)
  if (action === 'void_market') finish(market, undefined, payload.reason)
}
export function demoRecordScore(team: TeamSide, scoreType: ScoreType) {
  if (state.game.periodStatus !== 'live') throw new Error('Start a quarter first')
  const score: DemoScore = { game: structuredClone(state.game) }
  const prefix = team === 'home' ? 'home' : 'away'
  state.game[`${prefix}Goals`] += scoreType === 'goal' ? 1 : 0
  state.game[`${prefix}Behinds`] += scoreType === 'behind' ? 1 : 0
  state.game[`${prefix}Points`] += scoreType === 'goal' ? 6 : 1
  if (scoreType === 'goal') {
    const market = markets.find((m) => !m.settledAt)
    if (market) { finish(market, market.options.find((o) => o.optionKey === team)!.id); score.settledId = market.id }
    openMarket(); score.openedSequence = markets.at(-1)!.sequence
  }
  scores.push(score); state.game.canUndo = true
}
export function demoUndo() {
  if (!state.game.canUndo) return
  const score = scores.pop()!
  if (score.openedSequence) {
    for (const market of markets.slice().reverse().filter((m) => m.sequence >= score.openedSequence! && m.quarter === state.game.quarter)) {
      if (market.status === 'settled') reverse(market)
      if (market.status !== 'void') finish(market, undefined, 'Goal undone — later prediction refunded')
    }
    const original = markets.find((m) => m.id === score.settledId)
    if (original) { reverse(original); original.status = Date.now() < Date.parse(original.locksAt!) ? 'open' : 'locked' }
  }
  state.game = { ...score.game, version: state.game.version, canUndo: scores.length > 0 }
}
export function demoPause(paused: boolean) { state.game.bettingPaused = paused }
export function demoStartQuarter(quarter: number) {
  if (state.game.periodStatus === 'live' || state.game.periodStatus === 'final') throw new Error('Quarter cannot start')
  if (quarter !== (state.game.periodStatus === 'pre_match' ? 1 : state.game.quarter + 1)) throw new Error('Start the next quarter')
  state.game.quarter = quarter; state.game.periodStatus = 'live'; openMarket()
}
export function demoEndQuarter() {
  if (state.game.periodStatus !== 'live') return
  const market = markets.find((m) => !m.settledAt)
  if (market) finish(market, undefined, 'Quarter ended')
  const squareId = winningSquareId(state.game.homePoints, state.game.awayPoints, state.grid)!
  state.quarterResults.push({ quarter: state.game.quarter, homePoints: state.game.homePoints, awayPoints: state.game.awayPoints,
    winningSquareId: squareId, winnerLabel: state.squares.find((s) => s.id === squareId)?.ownerLabel ?? null,
    settledAt: now(), quarterLadder: ladder(state.game.quarter) })
  state.game.periodStatus = state.game.quarter === 4 ? 'final' : 'break'; state.game.canUndo = false; scores = []
}
export function demoSetGrid(homeTeam: string, awayTeam: string, nextGrid: GridConfig) {
  state.event.homeTeam = homeTeam; state.event.awayTeam = awayTeam; state.grid = nextGrid
}
