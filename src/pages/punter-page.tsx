import { MarketCard } from '../components/market-card'
import { Ladder } from '../components/ladder'
import { useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { OfflineBanner } from '../components/offline-banner'
import { QuarterResults } from '../components/quarter-results'
import { Scoreboard } from '../components/scoreboard'
import { SquaresGrid } from '../components/squares-grid'
import { useLiveSnapshot } from '../hooks/use-live-snapshot'
import { backendConfigured, joinPlayer } from '../lib/api'
import { clearPlayerSession, getPlayerSession, newOpaqueToken, savePlayerSession } from '../lib/session'
import type { BoardName, PlayerSession, PlayerSnapshot } from '../types'

type Tab = 'squares' | 'kennel' | 'ladder'

export function PunterPage() {
  const [session, setSession] = useState<PlayerSession | null>(() => getPlayerSession())
  const [tab, setTab] = useState<Tab>('squares')
  const [joinOpen, setJoinOpen] = useState(!session)
  const { snapshot, loading, error, online, refresh, setSnapshot } = useLiveSnapshot(session?.token)
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
          <img className="brand__mark" src="/bulldogs-logo.png" alt="" />
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

        {tab === 'kennel' && snapshot && <MarketCard key={session?.token ?? 'public'} snapshot={snapshot} token={session?.token}
          online={online} reconcile={setSnapshot} refresh={refresh} />}
        {tab === 'ladder' && snapshot && <div className="kennel-stack">
          <p>Rankings use settled net profit, never balance or total stakes.</p>
          <Ladder title={`Q${snapshot.game.quarter} ladder`} entries={snapshot.quarterLadder} />
          <Ladder title={snapshot.game.periodStatus === 'final' ? 'Top Dog · final' : 'Top Dog · provisional'} entries={snapshot.topDogLadder} />
          {snapshot.quarterResults.map((result) => <Ladder key={result.quarter}
            title={result.ladderFinalizedAt === null ? `Q${result.quarter} · awaiting Studs results` : `Q${result.quarter} · final standings`}
            entries={result.quarterLadder} playerId={playerSnapshot?.player.id} />)}
        </div>}

      </main>

      {joinOpen && (
        <JoinDialog
          boardNames={snapshot?.boardNames ?? []}
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

export function JoinDialog({
  boardNames,
  online,
  onClose,
  onJoined,
}: {
  boardNames: BoardName[]
  online: boolean
  onClose: () => void
  onJoined: (session: PlayerSession) => void
}) {
  // Follows the board names as they load, until the guest picks a mode themselves.
  const [mode, setMode] = useState<'board' | 'nickname' | null>(null)
  const onBoard = mode ? mode === 'board' : boardNames.length > 0
  const setOnBoard = (board: boolean) => setMode(board ? 'board' : 'nickname')
  const [search, setSearch] = useState('')
  const [chosen, setChosen] = useState<BoardName | null>(null)
  const [nickname, setNickname] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const joinToken = useRef(newOpaqueToken())
  const matches = boardNames.filter((entry) => entry.name.toLowerCase().includes(search.trim().toLowerCase()))

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    const name = onBoard ? chosen?.name : nickname.trim()
    if (!name) return
    setBusy(true)
    setError(null)
    const randomToken = joinToken.current
    const token = backendConfigured ? randomToken : `${name}:${randomToken}`
    try {
      const joined = await joinPlayer(onBoard ? '' : name, '', token, onBoard ? chosen!.purchaseId : null)
      onJoined({ token, nickname: joined.player.nickname })
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
        <form onSubmit={submit}>
          {onBoard ? <>
            <p>Find your name on the squares board. Your squares and bonus Bones come with it.</p>
            <label>
              Your name
              <input autoFocus onChange={(event) => { setSearch(event.target.value); setChosen(null) }}
                placeholder="Start typing your name" value={search} />
            </label>
            <div className="board-name-list" role="listbox" aria-label="Names on the squares board">
              {matches.map((entry) => <button type="button" role="option" key={entry.purchaseId}
                aria-selected={chosen?.purchaseId === entry.purchaseId} disabled={entry.claimed}
                className={chosen?.purchaseId === entry.purchaseId ? 'board-name board-name--chosen' : 'board-name'}
                onClick={() => setChosen(entry)}>
                <strong>{entry.name}</strong>
                <span>{entry.claimed ? 'Already joined' : `${entry.squaresCount} square${entry.squaresCount === 1 ? '' : 's'}`}</span>
              </button>)}
              {matches.length === 0 && <p className="muted-note">No name matches. Check the spelling, or join with a nickname below.</p>}
            </div>
            <button type="button" className="link-button" onClick={() => setOnBoard(false)}>Not on the board? Pick a nickname</button>
          </> : <>
            <p>Pick a nickname. No password, no app download.</p>
            <label>
              Nickname
              <input autoFocus maxLength={24} minLength={2} onChange={(event) => setNickname(event.target.value)}
                placeholder="e.g. Macca" required value={nickname} />
            </label>
            {boardNames.length > 0 && <button type="button" className="link-button" onClick={() => setOnBoard(true)}>On the squares board? Find your name</button>}
          </>}
          {error && <div className="form-error" role="alert">{error}</div>}
          <button className="button button--wide button--gold" disabled={busy || !online || (onBoard && !chosen)} type="submit">
            {busy ? 'Joining…' : onBoard && chosen ? `Enter as ${chosen.name}` : 'Enter The Kennel'}
          </button>
          <small>The app never handles money. Bones have no cash value.</small>
        </form>
      </div>
    </div>
  )
}

export function LoadingScreen({ label }: { label: string }) {
  return (
    <div className="loading-screen" role="status">
      <img className="brand__mark" src="/bulldogs-logo.png" alt="" />
      <strong>{label}</strong>
    </div>
  )
}
