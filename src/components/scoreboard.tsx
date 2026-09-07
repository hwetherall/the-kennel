import type { EventConfig, GameState } from '../types'
import { quarterLabel, scoreLine } from '../lib/game'

interface ScoreboardProps {
  event: EventConfig
  game: GameState
  compact?: boolean
}

export function Scoreboard({ event, game, compact = false }: ScoreboardProps) {
  return (
    <section className={compact ? 'scoreboard scoreboard--compact' : 'scoreboard'} aria-label="Live score">
      <div className="scoreboard__status">
        <span className={game.periodStatus === 'live' ? 'live-dot' : 'status-dot'} aria-hidden="true" />
        {quarterLabel(game)}
      </div>
      <div className="scoreboard__teams">
        <div className="scoreboard__team">
          <span className="scoreboard__name">{event.homeTeam}</span>
          <strong>{scoreLine(game.homeGoals, game.homeBehinds, game.homePoints)}</strong>
        </div>
        <span className="scoreboard__versus">v</span>
        <div className="scoreboard__team scoreboard__team--away">
          <span className="scoreboard__name">{event.awayTeam}</span>
          <strong>{scoreLine(game.awayGoals, game.awayBehinds, game.awayPoints)}</strong>
        </div>
      </div>
      {game.bettingPaused && <div className="pause-pill">Game paused by host</div>}
    </section>
  )
}
