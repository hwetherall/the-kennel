import { feedAgeSeconds, feedDifferences } from '../lib/score-feed'
import type { HostSnapshot, ScoreType, TeamSide } from '../types'

const GRAND_FINAL_GAME = 38729

/** One-tap confirmation of scores the live feed has seen. The feed itself never scores. */
export function ScoreFeedPanel({ snapshot, disabled, onConfirm }: {
  snapshot: HostSnapshot; disabled: boolean; onConfirm: (team: TeamSide, scoreType: ScoreType) => void
}) {
  const feed = snapshot.scoreFeed
  if (!feed) return null
  const age = feedAgeSeconds(feed, snapshot.serverNow)
  const quiet = age > 75
  const differences = feedDifferences(snapshot.game, feed)
  const live = snapshot.game.periodStatus === 'live'
  const team = (side: TeamSide) => side === 'home' ? snapshot.event.homeTeam : snapshot.event.awayTeam
  const line = (goals: number, behinds: number) => `${goals}.${behinds} (${goals * 6 + behinds})`
  return <section className={`host-card score-feed${quiet ? ' score-feed--quiet' : ''}`} aria-live="polite">
    <div className="host-card__heading">
      <div><span className="eyebrow">Live feed assist{feed.sourceGameId !== GRAND_FINAL_GAME ? ' · TEST DATA' : ''}</span>
        <h2>{team('home')} {line(feed.homeGoals, feed.homeBehinds)} · {team('away')} {line(feed.awayGoals, feed.awayBehinds)}</h2></div>
      <span className="count-pill">{feed.timeLabel ?? 'Feed'} · {quiet ? `quiet ${Math.round(age / 60)} min` : `${age}s ago`}</span>
    </div>
    {quiet && <p className="form-error">The feed has not reported for over a minute. Keep scoring by hand; the buttons below still work.</p>}
    {differences.length === 0 && !quiet && <p className="muted-note">The app matches the feed.</p>}
    <div className="feed-actions">
      {differences.filter((d) => d.count > 0).map((d) => <button key={`${d.team}-${d.scoreType}`} className="button button--gold"
        disabled={disabled || !live} onClick={() => onConfirm(d.team, d.scoreType)}>
        Confirm {team(d.team)} {d.scoreType}{d.count > 1 ? ` (feed has ${d.count} more)` : ''}</button>)}
    </div>
    {differences.some((d) => d.count > 0) && !live && <p className="muted-note">Start the quarter to confirm scores.</p>}
    {differences.filter((d) => d.count < 0).map((d) => <p key={`${d.team}-${d.scoreType}-ahead`} className="form-error">
      The app has {-d.count} more {team(d.team)} {d.scoreType}{-d.count > 1 ? 's' : ''} than the feed. If that score was a mis-tap
      or was overturned, undo it; otherwise the feed may be catching up.</p>)}
    <small>Check the TV before confirming. Confirming is exactly the same as tapping the score button yourself.</small>
  </section>
}
