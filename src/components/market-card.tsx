import { useEffect, useRef, useState } from 'react'
import { ApiError, placeBet } from '../lib/api'
import { newIdempotencyKey } from '../lib/session'
import type { MarketSummary, PlayerSnapshot, PublicSnapshot } from '../types'
import { PoolSplit } from './pool-split'

export function useMarketClock(market: MarketSummary | null, serverNow: string) {
  const anchor = useRef({ serverNow, received: performance.now() })
  if (anchor.current.serverNow !== serverNow) anchor.current = { serverNow, received: performance.now() }
  const [, tick] = useState(0)
  useEffect(() => { const timer = window.setInterval(() => tick((v) => v + 1), 500); return () => clearInterval(timer) }, [])
  const estimated = Date.parse(serverNow) + performance.now() - anchor.current.received
  const seconds = market?.locksAt ? Math.max(0, Math.ceil((Date.parse(market.locksAt) - estimated) / 1000)) : 0
  return { seconds, open: market?.status === 'open' && seconds > 0 }
}
export function MarketSummaryCard({ market, serverNow }: { market: MarketSummary; serverNow: string }) {
  const { seconds, open } = useMarketClock(market, serverNow)
  const winner = market.options.find((option) => option.id === market.winningOptionId)
  return <section className="market-summary">
    <span className="eyebrow">Next Goal · Q{market.quarter}</span><h2>{market.title}</h2>
    <p role="status">{open ? `Locks in ${seconds}s` : market.status === 'void' ? `Refunded · ${market.voidReason}` : market.status === 'settled' ? `Settled · ${winner?.label}` : 'Locked · awaiting next goal'}</p>
    <PoolSplit market={market} />
    {market.status === 'void' && <small>Stakes returned. Net profit: 0 Bones.</small>}
  </section>
}
type PendingBet = { marketId: string; optionId: string; stake: number; key: string }
export function MarketCard({ snapshot, token, online, reconcile, refresh }: {
  snapshot: PublicSnapshot | PlayerSnapshot; token?: string; online: boolean;
  reconcile: (next: PlayerSnapshot) => void; refresh: () => Promise<void>;
}) {
  const market = snapshot.activeMarket
  const player = 'player' in snapshot ? snapshot.player : null
  const position = 'activeBet' in snapshot ? snapshot.activeBet : null
  const { open } = useMarketClock(market, snapshot.serverNow)
  const [selection, setSelection] = useState<string | null>(null)
  const storageKey = `kennel-pending-bet:${token ?? 'anonymous'}`
  const [pending, setPending] = useState<PendingBet | null>(() => {
    try { return JSON.parse(sessionStorage.getItem(storageKey) ?? 'null') } catch { return null }
  })
  const [busy, setBusy] = useState(false)
  const inFlight = useRef(false)
  const [message, setMessage] = useState<string | null>(null)
  const selected = position?.optionId ?? (market?.options.some((o) => o.id === selection) ? selection : null)
  const available = Math.max(0, Math.min(player?.balance ?? 0, market?.maxStake == null ? Infinity : market.maxStake - (position?.stake ?? 0)))
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
  return <div className="kennel-stack">
    <section className="bones-card"><span>Your Bones</span><strong>{player?.balance.toLocaleString() ?? 'Join to play'}</strong><small>Free to play. Bones have no cash value. Prizes are non-monetary.</small></section>
    {snapshot.game.bettingPaused && <p role="status">Betting is paused. Scoring continues; lock times stay the same.</p>}
    {pending && <div className="inline-error" role="status">{busy ? 'Confirming your stake…' : `Your ${pending.stake}-Bone request needs confirmation. Retry checks the same request, including after this market locks.`}
      <button className="button" disabled={busy || !online} onClick={() => void submit(pending)}>Retry original request</button>
    </div>}
    {message && <p role="status">{message}</p>}
    {market ? <section className="market-card">
      <MarketSummaryCard market={market} serverNow={snapshot.serverNow} />
      {position && <p className="position-note">Your position: {market.options.find((o) => o.id === position.optionId)?.label} · {position.stake} Bones. You can only increase this selection.</p>}
      <div className="market-options">{market.options.map((option) => <button key={option.id}
        className={selected === option.id ? 'button button--gold' : 'button button--ghost'} aria-pressed={selected === option.id}
        disabled={!player || !open || !online || busy || Boolean(pending) || snapshot.game.bettingPaused || Boolean(position && position.optionId !== option.id)}
        onClick={() => setSelection(option.id)}>{option.label}{selected === option.id ? ' · Selected' : ''}</button>)}</div>
      <div className="stake-buttons">{[25, 50, 100, available].map((stake, index) => <button key={index} className="button"
        disabled={!selected || !player || !open || !online || busy || Boolean(pending) || snapshot.game.bettingPaused || stake <= 0 || stake > available}
        onClick={() => void submit({ marketId: market.id, optionId: selected!, stake, key: newIdempotencyKey() })}>{index === 3 ? `Max (${available})` : `+${stake}`}</button>)}</div>
      {available === 0 && player && <p>No Bones available to increase this position.</p>}
      {market.maxStake && <p>{available} Bones available within your balance and market cap.</p>}
    </section> : <section className="market-card"><h2>No Next Goal market open</h2><p>{snapshot.game.periodStatus === 'pre_match' ? 'The host will open the first prediction with Q1.' : 'Check back when play resumes.'}</p></section>}
    {snapshot.recentMarket && <details className="market-card"><summary>Latest prediction result</summary><MarketSummaryCard market={snapshot.recentMarket} serverNow={snapshot.serverNow} /></details>}
    {'recentActivity' in snapshot && <details className="market-card"><summary>Recent Bones activity</summary><ul className="activity-list">{snapshot.recentActivity.map((entry) => <li key={entry.id}>
      <span>{entry.reversalOfId ? 'Reversal · ' : ''}{entry.kind.replaceAll('_', ' ')}</span><strong>{entry.amount > 0 ? '+' : ''}{entry.amount} Bones</strong>
    </li>)}</ul><small>Credits include returned stakes. Ladder rankings use net profit.</small></details>}
  </div>
}
