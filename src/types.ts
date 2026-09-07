export type TeamSide = 'home' | 'away'
export type ScoreType = 'goal' | 'behind'
export type PeriodStatus = 'pre_match' | 'live' | 'break' | 'final'

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
}

export interface PublicSnapshot {
  serverNow: string
  event: EventConfig
  game: GameState
  grid: GridConfig
  squares: Square[]
  quarterResults: QuarterResult[]
}

export interface PlayerSummary {
  id: string
  nickname: string
  squaresCount: number
  isSquareHolder: boolean
}

export interface PurchaseSummary {
  id: string
  purchaserName: string
  purchaserEmail: string
  squaresCount: number
  linkedPlayerId: string | null
}

export interface PlayerSnapshot extends PublicSnapshot {
  player: PlayerSummary
  ownedSquareIds: number[]
}

export interface HostSnapshot extends PublicSnapshot {
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
