export type TeamSide = 'home' | 'away'
export type ScoreType = 'goal' | 'behind'
export type PeriodStatus = 'pre_match' | 'live' | 'break' | 'final'

export type MarketStatus = 'draft' | 'open' | 'locked' | 'settled' | 'void'

export type MarketType = 'next_goal' | 'studs_v_spuds' | 'futures_winner' | 'futures_norm_smith'
export type StudsStat = 'disposals' | 'hitouts'

export interface MarketOption {
  id: string
  marketId: string
  /** 'home' | 'away' for team markets, 'athlete_a' | 'athlete_b' for Studs, 'athlete:<id>' or 'any_other_player' for Norm Smith. */
  optionKey: string
  label: string
  poolBones: number
  sortOrder: number
  betCount: number
  teamLabel?: string | null
}

export interface StudsReading {
  matchupId: string
  slot: number
  roundLabel: string
  stat: StudsStat
  baselineA: number | null
  baselineB: number | null
  endingA: number | null
  endingB: number | null
  quarterA: number | null
  quarterB: number | null
}

export interface SettlementSummary {
  winningPoolBones: number
  losingPoolBones: number
  dustBones: number
}

export interface MarketSummary {
  id: string
  sequence: number
  type: MarketType
  quarter: number | null
  title: string
  status: MarketStatus
  lockStrategy?: 'deadline' | 'bounce'
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
  studs?: StudsReading | null
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
  ladderFinalizedAt?: string | null
  quarterLadder: LadderEntry[]
}

export interface BoardName {
  purchaseId: string
  name: string
  squaresCount: number
  claimed: boolean
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
  /** Both Futures and every opened Studs matchup. */
  kennelMarkets: MarketSummary[]
  boardNames: BoardName[]
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
  /** One position per Futures or Studs market. */
  positions: PlayerMarketPosition[]
  recentActivity: LedgerEntry[]
}

export interface Athlete {
  id: string
  name: string
  team: string | null
}

export interface StudsMatchup {
  id: string
  quarter: number
  slot: number
  roundLabel: string
  stat: StudsStat
  athleteAId: string
  athleteAName: string
  athleteATeam: string | null
  athleteBId: string
  athleteBName: string
  athleteBTeam: string | null
  baselineA: number | null
  baselineB: number | null
  endingA: number | null
  endingB: number | null
  marketId: string | null
  marketStatus: MarketStatus | null
  resolvedAt: string | null
}

export interface HostSnapshot extends PublicSnapshot {
  markets: MarketSummary[]
  players: PlayerSummary[]
  purchases: PurchaseSummary[]
  athletes: Athlete[]
  studsMatchups: StudsMatchup[]
  /** Both Futures, including drafts. */
  futures: MarketSummary[]
  /** The live feed's latest reading, if the feed script is running. */
  scoreFeed?: ScoreFeed | null
}

export interface ScoreFeed {
  sourceGameId: number
  homeGoals: number
  homeBehinds: number
  awayGoals: number
  awayBehinds: number
  timeLabel: string | null
  complete: number | null
  receivedAt: string
}

export interface PlayerSession {
  token: string
  nickname: string
}

export interface HostSession {
  token: string
  expiresAt: string
}
