import type {
  GridConfig,
  HostSnapshot,
  PlayerSnapshot,
  PublicSnapshot,
  ScoreType,
  TeamSide,
} from '../types'
import { winningSquareId } from './game'

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

const listeners = new Set<() => void>()
let lastState: PublicSnapshot | null = null

function emit() {
  state = {
    ...state,
    serverNow: new Date().toISOString(),
    game: {
      ...state.game,
      version: state.game.version + 1,
      updatedAt: new Date().toISOString(),
    },
  }
  listeners.forEach((listener) => listener())
}

export function subscribeDemo(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function demoPublicSnapshot(): PublicSnapshot {
  return structuredClone({ ...state, serverNow: new Date().toISOString() })
}

export function demoPlayerSnapshot(token: string): PlayerSnapshot {
  const nickname = token.includes(':') ? token.split(':')[0] : 'Guest'
  return {
    ...demoPublicSnapshot(),
    player: {
      id: 'demo-player',
      nickname,
      squaresCount: 2,
      isSquareHolder: true,
      balance: 1500,
      quarterRank: null,
      topDogRank: null,
    },
    ownedSquareIds: [1, 53],
    activeBet: null,
    recentActivity: [],
  }
}

export function demoHostSnapshot(): HostSnapshot {
  return {
    ...demoPublicSnapshot(),
    markets: [],
    players: [
      { id: 'demo-player', nickname: 'Harry', squaresCount: 2, isSquareHolder: true, balance: 1500 },
      { id: 'demo-player-2', nickname: 'Macca', squaresCount: 1, isSquareHolder: true, balance: 1250 },
    ],
    purchases: [],
  }
}

export function demoRecordScore(team: TeamSide, scoreType: ScoreType) {
  lastState = structuredClone(state)
  const points = scoreType === 'goal' ? 6 : 1
  const prefix = team === 'home' ? 'home' : 'away'
  state = {
    ...state,
    game: {
      ...state.game,
      periodStatus: 'live',
      [`${prefix}Goals`]: state.game[`${prefix}Goals`] + (scoreType === 'goal' ? 1 : 0),
      [`${prefix}Behinds`]: state.game[`${prefix}Behinds`] + (scoreType === 'behind' ? 1 : 0),
      [`${prefix}Points`]: state.game[`${prefix}Points`] + points,
      canUndo: true,
    },
  }
  emit()
}

export function demoUndo() {
  if (!lastState) return
  const previous = lastState
  lastState = null
  state = { ...previous, game: { ...previous.game, canUndo: false } }
  emit()
}

export function demoPause(paused: boolean) {
  state = { ...state, game: { ...state.game, bettingPaused: paused } }
  emit()
}

export function demoStartQuarter(quarter: number) {
  state = { ...state, game: { ...state.game, quarter, periodStatus: 'live' } }
  emit()
}

export function demoEndQuarter() {
  const squareId = winningSquareId(state.game.homePoints, state.game.awayPoints, state.grid)
  if (!squareId) return
  const square = state.squares.find((candidate) => candidate.id === squareId)
  state = {
    ...state,
    game: {
      ...state.game,
      periodStatus: state.game.quarter === 4 ? 'final' : 'break',
    },
    quarterResults: [
      ...state.quarterResults.filter((result) => result.quarter !== state.game.quarter),
      {
        quarter: state.game.quarter,
        homePoints: state.game.homePoints,
        awayPoints: state.game.awayPoints,
        winningSquareId: squareId,
        winnerLabel: square?.ownerLabel ?? null,
        settledAt: new Date().toISOString(),
        quarterLadder: [],
      },
    ],
  }
  emit()
}

export function demoSetGrid(homeTeam: string, awayTeam: string, nextGrid: GridConfig) {
  state = {
    ...state,
    event: { ...state.event, homeTeam, awayTeam },
    grid: nextGrid,
  }
  emit()
}
