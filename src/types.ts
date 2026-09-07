export type TeamSide = 'home' | 'away'
export type ScoreType = 'goal' | 'behind'
export type PeriodStatus = 'pre_match' | 'live' | 'break' | 'final'

export type MarketStatus = 'draft' | 'open' | 'locked' | 'settled' | 'void'

export interface MarketOption {
  id: string
  marketId: string
  optionKey: TeamSide
  label: string
  poolBones: number
  sortOrder: number
  betCount: number
}

export interface SettlementSummary {
  winningPoolBones: number
  losingPoolBones: number
  dustBones: number
}

export interface MarketSummary {
  id: string
  sequence: number
  type: 'next_goal'
  quarter: number
  title: string
  status: MarketStatus
  opensAt: string | null
  locksAt: string | null
  settledAt: string | null
  winningOptionId: string | null
  maxStake: number | null
  countsTowardQuarterPrize: boolean
  sponsorLabel: string | null
  voidReason: string | null
  betCount: number
  totalPoolBones: number
  settlement: SettlementSummary | null
  options: MarketOption[]
}

export interface PlayerMarketPosition {
  id: string
  marketId: string
  optionId: string
  stake: number
  payout: number | null
  profit: number | null
  settledAt: string | null
}

export interface LadderEntry {
  rank: number
  playerId: string
  nickname: string
  profit: number
  isMe: boolean
}

export interface LedgerEntry {
  id: string
  kind: 'courtesy_grant' | 'square_bonus' | 'stake' | 'payout' | 'refund' | 'bark'
  amount: number
  marketId: string | null
  reversalOfId: string | null
  balanceAfter: number
  createdAt: string
}

export interface EventConfig {
  eventName: string
  eventCode: string
  venue: string
  startsAt: string
  timezone: string
  homeTeam: string
  awayTeam: string
  zeffyUrl: string | null
}

export interface GameState {
  quarter: number
  periodStatus: PeriodStatus
  homeGoals: number
  homeBehinds: number
  homePoints: number
  awayGoals: number
  awayBehinds: number
  awayPoints: number
  bettingPaused: boolean
  version: number
  updatedAt: string
  canUndo: boolean
}

export interface GridConfig {
  rowDigits: number[]
  colDigits: number[]
}

export interface Square {
  id: number
  rowIndex: number
  colIndex: number
  ownerLabel: string | null
}

export interface QuarterResult {
  quarter: number
  homePoints: number
  awayPoints: number
  winningSquareId: number
  winnerLabel: string | null
  settledAt: string
  quarterLadder: LadderEntry[]
}

export interface PublicSnapshot {
  serverNow: string
  event: EventConfig
  game: GameState
  grid: GridConfig
  squares: Square[]
  quarterResults: QuarterResult[]
  activeMarket: MarketSummary | null
  recentMarket: MarketSummary | null
  quarterLadder: LadderEntry[]
  topDogLadder: LadderEntry[]
}

export interface PlayerSummary {
  id: string
  nickname: string
  squaresCount: number
  isSquareHolder: boolean
  balance: number
}

export interface PurchaseSummary {
  id: string
  purchaserName: string
  purchaserEmail: string
  squaresCount: number
  linkedPlayerId: string | null
}

export interface PlayerSnapshot extends PublicSnapshot {
  player: PlayerSummary & { quarterRank: number | null; topDogRank: number | null }
  ownedSquareIds: number[]
  activeBet: PlayerMarketPosition | null
  recentActivity: LedgerEntry[]
}

export interface HostSnapshot extends PublicSnapshot {
  markets: MarketSummary[]
  players: PlayerSummary[]
  purchases: PurchaseSummary[]
}

export interface PlayerSession {
  token: string
  nickname: string
}

export interface HostSession {
  token: string
  expiresAt: string
}
