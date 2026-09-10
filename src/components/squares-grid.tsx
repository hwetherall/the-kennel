import { useMemo } from 'react'
import type { GameState, GridConfig, Square } from '../types'
import { LAST_DIGITS, liveSquareId } from '../lib/game'

interface SquaresGridProps {
  game: GameState
  grid: GridConfig
  squares: Square[]
  homeTeam: string
  awayTeam: string
  ownedSquareIds?: number[]
  winningSquareIds?: number[]
  projector?: boolean
  print?: boolean
}

const EMPTY_IDS: number[] = []

export function SquaresGrid({
  game,
  grid,
  squares,
  homeTeam,
  awayTeam,
  ownedSquareIds = EMPTY_IDS,
  winningSquareIds = EMPTY_IDS,
  projector = false,
  print = false,
}: SquaresGridProps) {
  const currentSquareId = liveSquareId(game, grid)
  const homeDigit = game.homePoints % 10
  const awayDigit = game.awayPoints % 10
  const owned = useMemo(() => new Set(ownedSquareIds), [ownedSquareIds])
  const winners = useMemo(() => new Set(winningSquareIds), [winningSquareIds])
  const squareByPosition = useMemo(
    () => new Map(squares.map((square) => [`${square.rowIndex}:${square.colIndex}`, square])),
    [squares],
  )

  return (
    <section className={`grid-card${projector ? ' grid-card--projector' : ''}${print ? ' grid-card--print' : ''}`}>
      <div className="grid-card__heading">
        <div>
          <span className="eyebrow">The main event</span>
          <h2>Grand Final Squares</h2>
        </div>
        <div className="grid-legend" aria-label="Grid legend">
          {ownedSquareIds.length > 0 && <span><i className="legend-swatch legend-swatch--mine" /> Yours</span>}
          <span><i className="legend-swatch legend-swatch--live" /> Live</span>
          <span><i className="legend-swatch legend-swatch--winner" /> Winner</span>
        </div>
      </div>
      <div className="axis-label axis-label--away">{awayTeam} last digit →</div>
      <div className="grid-shell">
        <div className="axis-label axis-label--home">{homeTeam} last digit →</div>
        <div className="squares-grid" role="grid" aria-label="100 square board">
          <div className="grid-corner" aria-hidden="true">H/A</div>
          {LAST_DIGITS.map((digit) => (
            <div
              className={`digit-header${digit === awayDigit ? ' digit-header--active' : ''}`}
              key={`col-${digit}`}
              role="columnheader"
            >
              {digit}
            </div>
          ))}
          {LAST_DIGITS.flatMap((rowDigit) => {
            const rowIndex = grid.rowDigits.indexOf(rowDigit)
            return [
              <div
                className={`digit-header digit-header--row${rowDigit === homeDigit ? ' digit-header--active' : ''}`}
                key={`row-${rowDigit}`}
                role="rowheader"
              >
                {rowDigit}
              </div>,
              ...LAST_DIGITS.map((colDigit) => {
                const colIndex = grid.colDigits.indexOf(colDigit)
                const square = squareByPosition.get(`${rowIndex}:${colIndex}`)
                if (!square) return <div className="square" key={`empty-${rowDigit}-${colDigit}`} />
                const isOwned = owned.has(square.id)
                const isLive = square.id === currentSquareId
                const isWinner = winners.has(square.id)
                const className = [
                  'square',
                  isOwned && 'square--mine',
                  isLive && 'square--live',
                  isWinner && 'square--winner',
                ].filter(Boolean).join(' ')

                return (
                  <div
                    className={className}
                    key={square.id}
                    role="gridcell"
                    aria-label={`${rowDigit}-${colDigit}: ${square.ownerLabel ?? 'Open square'}${isLive ? ', currently live' : ''}`}
                  >
                    <span className="square__number">#{square.id}</span>
                    <strong>{square.ownerLabel ?? '—'}</strong>
                  </div>
                )
              }),
            ]
          })}
        </div>
      </div>
    </section>
  )
}
