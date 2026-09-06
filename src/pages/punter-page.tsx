import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { OfflineBanner } from '../components/offline-banner'
import { QuarterResults } from '../components/quarter-results'
import { Scoreboard } from '../components/scoreboard'
import { SquaresGrid } from '../components/squares-grid'
import { useLiveSnapshot } from '../hooks/use-live-snapshot'
import { backendConfigured, joinPlayer } from '../lib/api'
import { clearPlayerSession, getPlayerSession, newOpaqueToken, savePlayerSession } from '../lib/session'
import type { PlayerSession, PlayerSnapshot } from '../types'

type Tab = 'squares' | 'kennel' | 'ladder'

export function PunterPage() {
  const [session, setSession] = useState<PlayerSession | null>(() => getPlayerSession())
  const [tab, setTab] = useState<Tab>('squares')
  const [joinOpen, setJoinOpen] = useState(!session)
  const { snapshot, loading, error, online, refresh } = useLiveSnapshot(session?.token)
  const playerSnapshot = snapshot && 'player' in snapshot ? (snapshot as PlayerSnapshot) : null
  const latestResult = useMemo(
    () => snapshot?.quarterResults.slice().sort((a, b) => b.quarter - a.quarter)[0],
    [snapshot],
  )

  function signOut() {
    clearPlayerSession()
    setSession(null)
    setJoinOpen(true)
  }

  if (loading && !snapshot) return <LoadingScreen label="Opening the gates…" />

  return (
    <div className="app-shell">
      <OfflineBanner online={online} />
      <header className="topbar">
        <Link className="brand" to="/" aria-label="The Kennel home">
          <span className="brand__mark" aria-hidden="true">DB</span>
          <span><strong>THE KENNEL</strong><small>Denver Bulldogs ARFC</small></span>
        </Link>
        {session ? (
          <button className="profile-chip" onClick={signOut} title="Forget this player on this device">
            <span>{playerSnapshot?.player.nickname ?? session.nickname}</span>
            <small>{playerSnapshot?.player.squaresCount ?? 0} squares</small>
          </button>
        ) : (
          <button className="button button--small" onClick={() => setJoinOpen(true)}>Join the night</button>
        )}
      </header>

      {snapshot && <Scoreboard event={snapshot.event} game={snapshot.game} compact />}

      <nav className="tabbar" aria-label="Game sections">
        {(['squares', 'kennel', 'ladder'] as Tab[]).map((item) => (
          <button
            className={tab === item ? 'tabbar__item tabbar__item--active' : 'tabbar__item'}
            key={item}
            onClick={() => setTab(item)}
          >
            {item === 'squares' ? 'Squares' : item === 'kennel' ? 'The Kennel' : 'Ladder'}
          </button>
        ))}
      </nav>

      {error && (
        <div className="inline-error" role="alert">
          {error} <button onClick={() => void refresh()}>Try again</button>
        </div>
      )}

      <main className="main-content">
        {tab === 'squares' && snapshot && (
          <>
            {playerSnapshot && playerSnapshot.ownedSquareIds.includes(
              snapshot.squares.find((square) =>
                square.rowIndex === snapshot.grid.rowDigits.indexOf(snapshot.game.homePoints % 10)
                && square.colIndex === snapshot.grid.colDigits.indexOf(snapshot.game.awayPoints % 10),
              )?.id ?? -1,
            ) && (
              <div className="live-banner">
                <span aria-hidden="true">★</span>
                You’re live on the current score. Hold the line!
              </div>
            )}
            {latestResult && latestResult.quarter === snapshot.game.quarter && snapshot.game.periodStatus !== 'live' && (
              <div className="winner-banner">
                <span>Q{latestResult.quarter} winner</span>
                <strong>{latestResult.winnerLabel ?? 'Open square'} · #{latestResult.winningSquareId}</strong>
              </div>
            )}
            <SquaresGrid
              game={snapshot.game}
              grid={snapshot.grid}
              squares={snapshot.squares}
              homeTeam={snapshot.event.homeTeam}
              awayTeam={snapshot.event.awayTeam}
              ownedSquareIds={playerSnapshot?.ownedSquareIds}
              winningSquareIds={snapshot.quarterResults.map((result) => result.winningSquareId)}
            />
            <div className="below-grid">
              <QuarterResults results={snapshot.quarterResults} />
              <section className="zeffy-card">
                <span className="eyebrow">Want in?</span>
                <h2>Back the Bulldogs</h2>
                <p>Squares are sold by the club through Zeffy. The app never handles payments.</p>
                {snapshot.event.zeffyUrl ? (
                  <a className="button button--gold" href={snapshot.event.zeffyUrl} target="_blank" rel="noreferrer">
                    Get squares on Zeffy ↗
                  </a>
                ) : (
                  <span className="muted-note">The purchase link will appear when sales open.</span>
                )}
              </section>
            </div>
          </>
        )}

        {tab === 'kennel' && (
          <ComingSoon
            eyebrow="Phase 2"
            title="Put your Bones where your mouth is."
            body="Next Goal markets land here after the Squares board is match-night ready. Bones have no cash value."
          />
        )}

        {tab === 'ladder' && (
          <ComingSoon
            eyebrow="Phase 2"
            title="Top Dog is still in the sheds."
            body="The quarter ladder and overall standings will appear here once the prediction game opens."
          />
        )}
      </main>

      {joinOpen && (
        <JoinDialog
          online={online}
          onClose={() => session && setJoinOpen(false)}
          onJoined={(nextSession) => {
            savePlayerSession(nextSession)
            setSession(nextSession)
            setJoinOpen(false)
          }}
        />
      )}
    </div>
  )
}

function JoinDialog({
  online,
  onClose,
  onJoined,
}: {
  online: boolean
  onClose: () => void
  onJoined: (session: PlayerSession) => void
}) {
  const [nickname, setNickname] = useState('')
  const [email, setEmail] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    const randomToken = newOpaqueToken()
    const token = backendConfigured ? randomToken : `${nickname.trim()}:${randomToken}`
    try {
      await joinPlayer(nickname.trim(), email.trim(), token)
      onJoined({ token, nickname: nickname.trim() })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Could not join')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="dialog-backdrop" role="presentation">
      <div className="join-dialog" role="dialog" aria-modal="true" aria-labelledby="join-title">
        <button className="dialog-close" onClick={onClose} aria-label="Close join form">×</button>
        <span className="eyebrow">Welcome to the watch party</span>
        <h1 id="join-title">Join the pack.</h1>
        <p>Pick a nickname. No password, no app download.</p>
        <form onSubmit={submit}>
          <label>
            Nickname
            <input
              autoFocus
              maxLength={24}
              minLength={2}
              onChange={(event) => setNickname(event.target.value)}
              placeholder="e.g. Macca"
              required
              value={nickname}
            />
          </label>
          <label>
            Zeffy email <span>optional</span>
            <input
              autoComplete="email"
              onChange={(event) => setEmail(event.target.value)}
              placeholder="Used to match your squares"
              type="email"
              value={email}
            />
          </label>
          {error && <div className="form-error" role="alert">{error}</div>}
          <button className="button button--wide button--gold" disabled={busy || !online} type="submit">
            {busy ? 'Joining…' : 'Enter The Kennel'}
          </button>
          <small>Your email is only used to match a Zeffy purchase. The app does not handle money.</small>
        </form>
      </div>
    </div>
  )
}

function ComingSoon({ eyebrow, title, body }: { eyebrow: string; title: string; body: string }) {
  return (
    <section className="coming-soon">
      <span className="eyebrow">{eyebrow}</span>
      <div className="bone-mark" aria-hidden="true">◆</div>
      <h1>{title}</h1>
      <p>{body}</p>
    </section>
  )
}

export function LoadingScreen({ label }: { label: string }) {
  return (
    <div className="loading-screen" role="status">
      <span className="brand__mark">DB</span>
      <strong>{label}</strong>
    </div>
  )
}
