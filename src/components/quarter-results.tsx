import type { QuarterResult } from '../types'

export function QuarterResults({ results }: { results: QuarterResult[] }) {
  if (results.length === 0) {
    return (
      <section className="results-card empty-state">
        <span className="eyebrow">Siren winners</span>
        <h2>All to play for</h2>
        <p>The winning square will light up at each quarter siren.</p>
      </section>
    )
  }

  return (
    <section className="results-card">
      <span className="eyebrow">Siren winners</span>
      <div className="result-list">
        {results.slice().sort((a, b) => b.quarter - a.quarter).map((result) => (
          <article className="result-row" key={result.quarter}>
            <span className="result-row__quarter">Q{result.quarter}</span>
            <div>
              <strong>{result.winnerLabel ?? 'Open square'}</strong>
              <span>Square #{result.winningSquareId} · {result.homePoints}–{result.awayPoints}</span>
            </div>
          </article>
        ))}
      </div>
    </section>
  )
}
