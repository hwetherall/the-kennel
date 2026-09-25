import { useEffect, useRef, useState } from 'react'
import { ApiError, placeBet } from '../lib/api'
import { newIdempotencyKey } from '../lib/session'
import type { MarketOption, MarketSummary, PlayerMarketPosition, PlayerSnapshot, PublicSnapshot } from '../types'
import { PoolSplit } from './pool-split'

export function useMarketClock(market: MarketSummary | null, serverNow: string) {
  const anchor = useRef({ serverNow, received: performance.now() })
  if (anchor.current.serverNow !== serverNow) anchor.current = { serverNow, received: performance.now() }
  const [, tick] = useState(0)
  useEffect(() => { const timer = window.setInterval(() => tick((v) => v + 1), 500); return () => clearInterval(timer) }, [])
  const estimated = Date.parse(serverNow) + performance.now() - anchor.current.received
  const seconds = market?.locksAt ? Math.max(0, Math.ceil((Date.parse(market.locksAt) - estimated) / 1000)) : 0
  // Bounce-locked markets have no clock: the server locks them when play starts.
  const bounce = market?.lockStrategy === 'bounce'
  return { seconds, open: market?.status === 'open' && (bounce || seconds > 0) }
}

export const optionLabel = (option: MarketOption) => option.teamLabel ? `${option.label} (${option.teamLabel})` : option.label
export const statLabel = (stat: string) => stat === 'hitouts' ? 'hit-outs' : 'disposals'

export function marketEyebrow(market: MarketSummary) {
  if (market.type === 'studs_v_spuds') return `Studs v Spuds · Q${market.quarter}${market.studs ? ` · ${market.studs.roundLabel}` : ''}`
  if (market.type === 'futures_winner') return 'Future · Match winner'
  if (market.type === 'futures_norm_smith') return 'Future · Norm Smith Medal'
  return `Next Goal · Q${market.quarter}`
}

function statusLine(market: MarketSummary, open: boolean, seconds: number) {
  const winner = market.options.find((option) => option.id === market.winningOptionId)
  if (market.status === 'void') return `Refunded · ${market.voidReason}`
  if (market.status === 'settled') return `Settled · ${winner ? optionLabel(winner) : ''}`
  if (market.type === 'studs_v_spuds') return open ? `Open · locks at the Q${market.quarter} bounce` : `Locked · result at the Q${market.quarter} siren`
  if (market.type !== 'next_goal') return open ? 'Open · locks at the first bounce' : 'Locked · result at full time'
  return open ? `Locks in ${seconds}s` : 'Locked · awaiting next goal'
}

export function MarketSummaryCard({ market, serverNow }: { market: MarketSummary; serverNow: string }) {
  const { seconds, open } = useMarketClock(market, serverNow)
  const [optionA, optionB] = market.options
  const studs = market.studs
  return <section className="market-summary">
    <span className="eyebrow">{marketEyebrow(market)}</span><h2>{market.title}</h2>
    {studs && <p className="muted-note">Most {statLabel(studs.stat)} in Q{market.quarter} only</p>}
    <p role="status">{statusLine(market, open, seconds)}</p>
    {studs && studs.quarterA !== null && studs.quarterB !== null && <p className="studs-reading">
      This quarter: {optionA?.label} {studs.quarterA} · {optionB?.label} {studs.quarterB}
    </p>}
    <PoolSplit market={market} />
    {market.status === 'void' && <small>Stakes returned. Net profit: 0 Bones.</small>}
  </section>
}

type PendingBet = { marketId: string; optionId: string; stake: number; key: string }

function BackingPanel({ market, position, snapshot, player, blocked, onSubmit }: {
  market: MarketSummary; position: PlayerMarketPosition | null; snapshot: PublicSnapshot;
  player: PlayerSnapshot['player'] | null; blocked: boolean; onSubmit: (intent: PendingBet) => void;
}) {
  const { open } = useMarketClock(market, snapshot.serverNow)
  const [selection, setSelection] = useState<string | null>(null)
  const selected = position?.optionId ?? (market.options.some((o) => o.id === selection) ? selection : null)
  const available = Math.max(0, Math.min(player?.balance ?? 0, market.maxStake == null ? Infinity : market.maxStake - (position?.stake ?? 0)))
  const disabled = !player || !open || blocked || snapshot.game.bettingPaused
  const mine = position && market.options.find((o) => o.id === position.optionId)
  return <section className="market-card">
    <MarketSummaryCard market={market} serverNow={snapshot.serverNow} />
    {position && mine && <p className="position-note">
      Your position: {optionLabel(mine)} · {position.stake} Bones
      {position.settledAt ? ` · ${position.profit! > 0 ? '+' : ''}${position.profit} profit` : open ? '. You can only increase this selection.' : ''}
    </p>}
    {market.status === 'open' && <>
      <div className="market-options">{market.options.map((option) => <button key={option.id}
        className={selected === option.id ? 'button button--gold' : 'button button--ghost'} aria-pressed={selected === option.id}
        disabled={disabled || Boolean(position && position.optionId !== option.id)}
        onClick={() => setSelection(option.id)}>{optionLabel(option)}{selected === option.id ? ' · Selected' : ''}</button>)}</div>
      <div className="stake-buttons">{[25, 50, 100, available].map((stake, index) => <button key={index} className="button"
        disabled={!selected || disabled || stake <= 0 || stake > available}
        onClick={() => onSubmit({ marketId: market.id, optionId: selected!, stake, key: newIdempotencyKey() })}>{index === 3 ? `Max (${available})` : `+${stake}`}</button>)}</div>
      {available === 0 && player && <p>No Bones available to increase this position.</p>}
      {market.maxStake && <p>{available} Bones available within your balance and the {market.maxStake}-Bone cap.</p>}
    </>}
    {market.type.startsWith('futures') && <small>Counts toward Top Dog only, not the quarter ladders.</small>}
    {market.type === 'studs_v_spuds' && <small>Counts toward the Q{market.quarter} ladder.</small>}
  </section>
}

export function MarketCard({ snapshot, token, online, reconcile, refresh }: {
  snapshot: PublicSnapshot | PlayerSnapshot; token?: string; online: boolean;
  reconcile: (next: PlayerSnapshot) => void; refresh: () => Promise<void>;
}) {
  const player = 'player' in snapshot ? snapshot.player : null
  const positions = 'positions' in snapshot ? snapshot.positions : []
  const storageKey = `kennel-pending-bet:${token ?? 'anonymous'}`
  const [pending, setPending] = useState<PendingBet | null>(() => {
    try { return JSON.parse(sessionStorage.getItem(storageKey) ?? 'null') } catch { return null }
  })
  const [busy, setBusy] = useState(false)
  const inFlight = useRef(false)
  const [message, setMessage] = useState<string | null>(null)
  // One stake request at a time, across every market, so a retry can never race another.
  async function submit(intent: PendingBet) {
    if (!token || !online || inFlight.current) return
    inFlight.current = true; setBusy(true); setPending(intent); setMessage(null)
    sessionStorage.setItem(storageKey, JSON.stringify(intent))
    try {
      reconcile(await placeBet(token, intent.marketId, intent.optionId, intent.stake, intent.key))
      await refresh() // A receipt may contain an older snapshot; fetch present truth too.
      setPending(null); sessionStorage.removeItem(storageKey)
      setMessage('Stake accepted. Your selection is fixed for this market.')
    } catch (error) {
      if (error instanceof ApiError && !error.uncertain) { setPending(null); sessionStorage.removeItem(storageKey) }
      setMessage(error instanceof Error ? error.message : 'Could not confirm your stake')
    } finally { inFlight.current = false; setBusy(false) }
  }
  const blocked = !online || busy || Boolean(pending)
  const panel = (market: MarketSummary, position: PlayerMarketPosition | null) => <BackingPanel key={market.id}
    market={market} position={position} snapshot={snapshot} player={player} blocked={blocked} onSubmit={(intent) => void submit(intent)} />
  const positionFor = (market: MarketSummary) => positions.find((p) => p.marketId === market.id) ?? null

  const kennelMarkets = snapshot.kennelMarkets ?? []
  const studs = kennelMarkets.filter((m) => m.type === 'studs_v_spuds')
  const liveStuds = studs.filter((m) => !m.settledAt)
  const settledStuds = studs.filter((m) => m.settledAt).reverse()
  const futures = kennelMarkets.filter((m) => m.type !== 'studs_v_spuds')

  const nextGoal = snapshot.activeMarket
    ? panel(snapshot.activeMarket, 'activeBet' in snapshot ? snapshot.activeBet : null)
    : <section className="market-card" key="next-goal"><h2>No Next Goal market open</h2><p>{snapshot.game.periodStatus === 'pre_match' ? 'Next Goal opens with the Q1 bounce.' : 'Next Goal returns when play resumes.'}</p></section>
  const studsSection = liveStuds.length > 0 && <div className="kennel-group" key="studs">
    <h2 className="kennel-group__title">Studs v Spuds</h2>
    <p className="muted-note">Who gets more in the coming quarter? Open during the break, locked at the bounce, paid at the siren.</p>
    {liveStuds.map((m) => panel(m, positionFor(m)))}
  </div>
  const futuresSection = futures.length > 0 && <div className="kennel-group" key="futures">
    <h2 className="kennel-group__title">Futures</h2>
    {futures.map((m) => panel(m, positionFor(m)))}
  </div>
  // Studs fills the breaks and Next Goal fills the play, so lead with whichever is live.
  const sections = snapshot.game.periodStatus === 'live' ? [nextGoal, studsSection, futuresSection] : [studsSection, futuresSection, nextGoal]

  return <div className="kennel-stack">
    <section className="bones-card"><span>Your Bones</span><strong>{player?.balance.toLocaleString() ?? 'Join to play'}</strong><small>Free to play. Bones have no cash value. Prizes are non-monetary.</small></section>
    {snapshot.game.bettingPaused && <p role="status">Betting is paused. Scoring continues; lock times stay the same.</p>}
    {pending && <div className="inline-error" role="status">{busy ? 'Confirming your stake…' : `Your ${pending.stake}-Bone request needs confirmation. Retry checks the same request, including after this market locks.`}
      <button className="button" disabled={busy || !online} onClick={() => void submit(pending)}>Retry original request</button>
    </div>}
    {message && <p role="status">{message}</p>}
    {sections}
    {settledStuds.length > 0 && <details className="market-card"><summary>Studs v Spuds results</summary>
      {settledStuds.map((m) => <MarketSummaryCard key={m.id} market={m} serverNow={snapshot.serverNow} />)}</details>}
    {snapshot.recentMarket && <details className="market-card"><summary>Latest prediction result</summary><MarketSummaryCard market={snapshot.recentMarket} serverNow={snapshot.serverNow} /></details>}
    {'recentActivity' in snapshot && <details className="market-card"><summary>Recent Bones activity</summary><ul className="activity-list">{snapshot.recentActivity.map((entry) => <li key={entry.id}>
      <span>{entry.reversalOfId ? 'Reversal · ' : ''}{entry.kind.replaceAll('_', ' ')}</span><strong>{entry.amount > 0 ? '+' : ''}{entry.amount} Bones</strong>
    </li>)}</ul><small>Credits include returned stakes. Ladder rankings use net profit.</small></details>}
  </div>
}
