import { SquaresGrid } from '../components/squares-grid'
import { useLiveSnapshot } from '../hooks/use-live-snapshot'
import { scoreLine } from '../lib/game'
import { LoadingScreen } from './punter-page'

export function PrintPage() {
  const { snapshot, loading } = useLiveSnapshot()
  if (loading || !snapshot) return <LoadingScreen label="Preparing the backup grid…" />

  return (
    <main className="print-page">
      <header className="print-header">
        <div><span className="eyebrow">Denver Bulldogs ARFC</span><h1>Grand Final Squares</h1></div>
        <div><strong>{snapshot.event.homeTeam} v {snapshot.event.awayTeam}</strong><span>{snapshot.event.venue}</span></div>
        <button className="button print-button" onClick={() => window.print()}>Print grid</button>
      </header>
      <SquaresGrid
        print
        game={snapshot.game}
        grid={snapshot.grid}
        squares={snapshot.squares}
        homeTeam={snapshot.event.homeTeam}
        awayTeam={snapshot.event.awayTeam}
        winningSquareIds={snapshot.quarterResults.map((result) => result.winningSquareId)}
      />
      <footer className="print-footer">
        <span>Live score: {scoreLine(snapshot.game.homeGoals, snapshot.game.homeBehinds, snapshot.game.homePoints)} – {scoreLine(snapshot.game.awayGoals, snapshot.game.awayBehinds, snapshot.game.awayPoints)}</span>
        <span>Printed {new Date().toLocaleString()}</span>
      </footer>
    </main>
  )
}
