import { MarketSummaryCard } from '../components/market-card'
import { Ladder } from '../components/ladder'
import { Link } from 'react-router-dom'
import { OfflineBanner } from '../components/offline-banner'
import { QuarterResults } from '../components/quarter-results'
import { Scoreboard } from '../components/scoreboard'
import { SquaresGrid } from '../components/squares-grid'
import { useLiveSnapshot } from '../hooks/use-live-snapshot'
import { LoadingScreen } from './punter-page'

export function ScreenPage() {
  const { snapshot, loading, error, online, refresh } = useLiveSnapshot()
  if (loading && !snapshot) return <LoadingScreen label="Warming up the big screen…" />
  if (!snapshot) return <div className="screen-error">{error}<button onClick={() => void refresh()}>Try again</button></div>

  const latest = snapshot.quarterResults.slice().sort((a, b) => b.quarter - a.quarter)[0]

  return (
    <main className="projector-shell">
      <OfflineBanner online={online} />
      <header className="projector-header">
        <div className="brand brand--light"><span className="brand__mark">DB</span><span><strong>THE KENNEL</strong><small>Grand Final Night</small></span></div>
        <span>{snapshot.event.venue}</span>
        <Link to="/" aria-label="Open mobile view">Mobile view</Link>
      </header>
      <Scoreboard event={snapshot.event} game={snapshot.game} />
      {latest && snapshot.game.periodStatus !== 'live' && (
        <div className="projector-winner">
          <span>Q{latest.quarter} winning square</span>
          <strong>#{latest.winningSquareId} · {latest.winnerLabel ?? 'Open square'}</strong>
        </div>
      )}
      <div className="projector-layout">
        <SquaresGrid
          projector
          game={snapshot.game}
          grid={snapshot.grid}
          squares={snapshot.squares}
          homeTeam={snapshot.event.homeTeam}
          awayTeam={snapshot.event.awayTeam}
          winningSquareIds={snapshot.quarterResults.map((result) => result.winningSquareId)}
        />
        <aside className="projector-sidebar">
          <QuarterResults results={snapshot.quarterResults} />
          <section className="next-up-card">
            {snapshot.activeMarket ? <MarketSummaryCard market={snapshot.activeMarket} serverNow={snapshot.serverNow} /> : <p>Next Goal opens when play resumes.</p>}
            <small>Bones have no cash value.</small>
          </section>
          <Ladder title={snapshot.game.periodStatus === 'final' ? 'Top Dog · final' : `Q${snapshot.game.quarter} · top five`}
            entries={(snapshot.game.periodStatus === 'final' ? snapshot.topDogLadder : snapshot.quarterLadder).slice(0, 5)} />
          {snapshot.recentMarket && <details><summary>Latest result</summary><MarketSummaryCard market={snapshot.recentMarket} serverNow={snapshot.serverNow} /></details>}
        </aside>
      </div>
    </main>
  )
}
