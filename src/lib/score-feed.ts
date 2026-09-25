import type { GameState, ScoreFeed, ScoreType, TeamSide } from '../types'

export interface FeedDifference { team: TeamSide; scoreType: ScoreType; count: number }

/**
 * Where the live feed and the app's own score disagree. A positive count is a
 * score the feed has and the app does not: the host can confirm it with a tap.
 * A negative count means the app is ahead of the feed, from a mis-tap or an
 * overturned goal; the host decides whether to undo.
 */
export function feedDifferences(game: GameState, feed: ScoreFeed): FeedDifference[] {
  const pairs: [TeamSide, ScoreType, number, number][] = [
    ['home', 'goal', feed.homeGoals, game.homeGoals], ['home', 'behind', feed.homeBehinds, game.homeBehinds],
    ['away', 'goal', feed.awayGoals, game.awayGoals], ['away', 'behind', feed.awayBehinds, game.awayBehinds],
  ]
  return pairs.filter(([, , fed, app]) => fed !== app).map(([team, scoreType, fed, app]) => ({ team, scoreType, count: fed - app }))
}

/** Seconds since the feed script last reported, measured on the server clock. */
export function feedAgeSeconds(feed: ScoreFeed, serverNow: string) {
  return Math.max(0, Math.round((Date.parse(serverNow) - Date.parse(feed.receivedAt)) / 1000))
}
