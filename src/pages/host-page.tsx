import { useState } from 'react'
import { Link } from 'react-router-dom'
import { OfflineBanner } from '../components/offline-banner'
import { Scoreboard } from '../components/scoreboard'
import { useLiveHostSnapshot } from '../hooks/use-live-snapshot'
import {
  endQuarter,
  hostLogin,
  linkPurchase,
  recordScore,
  setGrid,
  setPause,
  startQuarter,
  undoLatestScore,
} from '../lib/api'
import { shuffledDigits } from '../lib/game'
import {
  clearHostSession,
  getHostSession,
  newIdempotencyKey,
  saveHostSession,
} from '../lib/session'
import type { HostSession, HostSnapshot, ScoreType, TeamSide } from '../types'
import { LoadingScreen } from './punter-page'

export function HostPage() {
  const [session, setSession] = useState<HostSession | null>(() => getHostSession())
  const { snapshot, setSnapshot, loading, error, online } = useLiveHostSnapshot(session?.token)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  async function act(label: string, action: () => Promise<HostSnapshot>) {
    if (!session || !online || busy) return
    setBusy(label)
    setActionError(null)
    try {
      setSnapshot(await action())
    } catch (caught) {
      setActionError(caught instanceof Error ? caught.message : 'Host action failed')
    } finally {
      setBusy(null)
    }
  }

  if (!session) {
    return <HostLogin onLogin={(next) => { saveHostSession(next); setSession(next) }} />
  }
  if (loading && !snapshot) return <LoadingScreen label="Opening host console…" />
  if (!snapshot) return <HostLogin error={error ?? undefined} onLogin={(next) => { saveHostSession(next); setSession(next) }} />

  const nextQuarter = Math.min(4, snapshot.game.quarter + 1)
  const isLive = snapshot.game.periodStatus === 'live'
  const scoreDisabled = Boolean(busy) || !online || !isLive

  return (
    <div className="host-shell">
      <OfflineBanner online={online} />
      <header className="host-topbar">
        <div>
          <span className="eyebrow">Single operator console</span>
          <h1>Match control</h1>
        </div>
        <nav>
          <Link to="/screen" target="_blank">Projector ↗</Link>
          <Link to="/host/print" target="_blank">Print grid ↗</Link>
          <button onClick={() => { clearHostSession(); setSession(null) }}>Lock</button>
        </nav>
      </header>

      <main className="host-main">
        <Scoreboard event={snapshot.event} game={snapshot.game} />
        {(actionError || error) && <div className="inline-error" role="alert">{actionError || error}</div>}

        <section className="host-card score-controls">
          <div className="host-card__heading">
            <div><span className="eyebrow">Q{snapshot.game.quarter}</span><h2>Score entry</h2></div>
            <button
              className="button button--danger-outline"
              disabled={!snapshot.game.canUndo || Boolean(busy) || !online}
              onClick={() => void act('undo', () => undoLatestScore(session.token, newIdempotencyKey()))}
            >
              {busy === 'undo' ? 'Undoing…' : '↶ Undo last score'}
            </button>
          </div>
          <div className="score-button-grid">
            <ScoreButton
              disabled={scoreDisabled}
              label={`${snapshot.event.homeTeam} goal`}
              points="+6"
              onClick={() => void act('home-goal', () => recordScore(session.token, 'home', 'goal', newIdempotencyKey()))}
            />
            <ScoreButton
              disabled={scoreDisabled}
              label={`${snapshot.event.homeTeam} behind`}
              points="+1"
              onClick={() => void act('home-behind', () => recordScore(session.token, 'home', 'behind', newIdempotencyKey()))}
              secondary
            />
            <ScoreButton
              away
              disabled={scoreDisabled}
              label={`${snapshot.event.awayTeam} goal`}
              points="+6"
              onClick={() => void act('away-goal', () => recordScore(session.token, 'away', 'goal', newIdempotencyKey()))}
            />
            <ScoreButton
              away
              disabled={scoreDisabled}
              label={`${snapshot.event.awayTeam} behind`}
              points="+1"
              onClick={() => void act('away-behind', () => recordScore(session.token, 'away', 'behind', newIdempotencyKey()))}
              secondary
            />
          </div>
        </section>

        <div className="host-columns">
          <section className="host-card">
            <span className="eyebrow">Match flow</span>
            <h2>Quarter controls</h2>
            <div className="stacked-actions">
              {!isLive && snapshot.game.periodStatus !== 'final' && (
                <button
                  className="button button--wide button--gold"
                  disabled={Boolean(busy) || !online}
                  onClick={() => void act('start', () => startQuarter(
                    session.token,
                    snapshot.game.periodStatus === 'pre_match' ? 1 : nextQuarter,
                    newIdempotencyKey(),
                  ))}
                >
                  Start {snapshot.game.periodStatus === 'pre_match' ? 'Q1' : `Q${nextQuarter}`}
                </button>
              )}
              {isLive && (
                <button
                  className="button button--wide"
                  disabled={Boolean(busy) || !online}
                  onClick={() => void act('end', () => endQuarter(session.token, newIdempotencyKey()))}
                >
                  Sound Q{snapshot.game.quarter} siren
                </button>
              )}
              <button
                className={snapshot.game.bettingPaused ? 'button button--wide button--green' : 'button button--wide button--danger'}
                disabled={Boolean(busy) || !online}
                onClick={() => void act('pause', () => setPause(
                  session.token,
                  !snapshot.game.bettingPaused,
                  newIdempotencyKey(),
                ))}
              >
                {snapshot.game.bettingPaused ? 'Resume game' : 'Pause all game actions'}
              </button>
            </div>
          </section>

          <GridSettings
            disabled={Boolean(busy) || !online || snapshot.game.homePoints + snapshot.game.awayPoints > 0}
            snapshot={snapshot}
            onSave={(homeTeam, awayTeam, rowDigits, colDigits) => void act('grid', () => setGrid(
              session.token,
              homeTeam,
              awayTeam,
              { rowDigits, colDigits },
              newIdempotencyKey(),
            ))}
          />
        </div>

        <PurchaseLinker
          disabled={Boolean(busy) || !online}
          snapshot={snapshot}
          onLink={(purchaseId, playerId) => void act('link', () => linkPurchase(
            session.token,
            purchaseId,
            playerId,
            newIdempotencyKey(),
          ))}
        />
      </main>
    </div>
  )
}

function HostLogin({ onLogin, error: initialError }: { onLogin: (session: HostSession) => void; error?: string }) {
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(initialError ?? null)

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      onLogin(await hostLogin(pin))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not unlock console')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="host-login">
      <div className="host-login__card">
        <span className="brand__mark">DB</span>
        <span className="eyebrow">Host only</span>
        <h1>Open the console.</h1>
        <p>One operator. Big buttons. Every score can be undone.</p>
        <form onSubmit={submit}>
          <label>
            Host PIN
            <input
              autoFocus
              inputMode="numeric"
              minLength={4}
              onChange={(event) => setPin(event.target.value)}
              placeholder="••••"
              required
              type="password"
              value={pin}
            />
          </label>
          {error && <div className="form-error">{error}</div>}
          <button className="button button--wide button--gold" disabled={busy} type="submit">
            {busy ? 'Opening…' : 'Open console'}
          </button>
          {!import.meta.env.VITE_INSFORGE_URL && <small>Local demo PIN: 2468</small>}
        </form>
        <Link to="/">← Back to the board</Link>
      </div>
    </main>
  )
}

function ScoreButton({
  label,
  points,
  onClick,
  disabled,
  away = false,
  secondary = false,
}: {
  label: string
  points: string
  onClick: () => void
  disabled: boolean
  away?: boolean
  secondary?: boolean
}) {
  return (
    <button
      className={`score-button${away ? ' score-button--away' : ''}${secondary ? ' score-button--secondary' : ''}`}
      disabled={disabled}
      onClick={onClick}
    >
      <span>{label}</span><strong>{points}</strong>
    </button>
  )
}

function GridSettings({
  snapshot,
  disabled,
  onSave,
}: {
  snapshot: HostSnapshot
  disabled: boolean
  onSave: (home: string, away: string, rows: number[], columns: number[]) => void
}) {
  const [home, setHome] = useState(snapshot.event.homeTeam)
  const [away, setAway] = useState(snapshot.event.awayTeam)
  const [rows, setRows] = useState(snapshot.grid.rowDigits)
  const [columns, setColumns] = useState(snapshot.grid.colDigits)

  return (
    <section className="host-card">
      <span className="eyebrow">Lock before bounce</span>
      <h2>Teams & digits</h2>
      <div className="team-inputs">
        <label>Home<input disabled={disabled} value={home} onChange={(event) => setHome(event.target.value)} /></label>
        <label>Away<input disabled={disabled} value={away} onChange={(event) => setAway(event.target.value)} /></label>
      </div>
      <div className="digit-preview"><span>Home</span>{rows.map((digit) => <i key={digit}>{digit}</i>)}</div>
      <div className="digit-preview"><span>Away</span>{columns.map((digit) => <i key={digit}>{digit}</i>)}</div>
      <div className="inline-actions">
        <button className="button button--ghost" disabled={disabled} onClick={() => { setRows(shuffledDigits()); setColumns(shuffledDigits()) }}>
          Shuffle digits
        </button>
        <button className="button" disabled={disabled || !home.trim() || !away.trim()} onClick={() => onSave(home.trim(), away.trim(), rows, columns)}>
          Save setup
        </button>
      </div>
      {disabled && <small>Team and digit setup locks after the first score.</small>}
    </section>
  )
}

function PurchaseLinker({ snapshot, disabled, onLink }: {
  snapshot: HostSnapshot
  disabled: boolean
  onLink: (purchaseId: string, playerId: string | null) => void
}) {
  return (
    <section className="host-card purchase-linker">
      <div className="host-card__heading">
        <div><span className="eyebrow">Squares desk</span><h2>Purchase matching</h2></div>
        <span className="count-pill">{snapshot.purchases.length} purchases</span>
      </div>
      {snapshot.purchases.length === 0 ? (
        <div className="empty-row">No Zeffy purchases have been imported yet.</div>
      ) : (
        <div className="purchase-list">
          {snapshot.purchases.map((purchase) => (
            <div className="purchase-row" key={purchase.id}>
              <div><strong>{purchase.purchaserName}</strong><span>{purchase.purchaserEmail} · {purchase.squaresCount} squares</span></div>
              <select
                disabled={disabled}
                onChange={(event) => onLink(purchase.id, event.target.value || null)}
                value={purchase.linkedPlayerId ?? ''}
              >
                <option value="">Not linked</option>
                {snapshot.players.map((player) => <option key={player.id} value={player.id}>{player.nickname}</option>)}
              </select>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}
