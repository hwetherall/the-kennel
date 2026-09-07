import { useState } from 'react'
import type { HostSnapshot } from '../types'
import type { MarketAction } from '../lib/api'
import { MarketSummaryCard } from './market-card'
import { Ladder } from './ladder'
export function HostMarkets({ snapshot, disabled, onAction }: { snapshot: HostSnapshot; disabled: boolean;
  onAction: (action: MarketAction, payload: { marketId?: string; winningOptionId?: string; reason?: string }) => void;
}) {
  const [winner, setWinner] = useState('')
  const [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState<'settle' | 'void' | null>(null)
  const market = snapshot.activeMarket
  const selected = market?.options.find((o) => o.id === winner)
  return <section className="host-card">
    <span className="eyebrow">Kennel recovery</span><h2>Next Goal controls</h2>
    <p>Goals normally settle and open predictions automatically. Use these controls to recover a missed market.</p>
    {market ? <>
      <MarketSummaryCard market={market} serverNow={snapshot.serverNow} />
      <button className="button" disabled={disabled || market.status !== 'open'} onClick={() => onAction('lock_market', { marketId: market.id })}>Lock prediction</button>
      <div className="team-inputs">
        <label>Winning team<select value={selected?.id ?? ''} disabled={disabled} onChange={(e) => { setWinner(e.target.value); setConfirm(null) }}>
          <option value="">Choose a team</option>{market.options.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
        </select></label>
        <button className="button" disabled={disabled || !selected} onClick={() => setConfirm('settle')}>Review settlement</button>
      </div>
      <label>Refund reason<input maxLength={200} value={reason} disabled={disabled} onChange={(e) => { setReason(e.target.value); setConfirm(null) }} /></label>
      <button className="button button--danger-outline" disabled={disabled || !reason.trim()} onClick={() => setConfirm('void')}>Review void and refund</button>
      {confirm && <div className="confirmation" role="group" aria-label="Confirm market recovery">
        <p>{confirm === 'settle' ? `Settle this prediction for ${selected?.label}? If nobody backed this team, all stakes refund.` : `Void this prediction and return every stake? Reason: ${reason}`}</p>
        <button className="button button--gold" disabled={disabled || (confirm === 'settle' && !selected)} onClick={() => {
          onAction(confirm === 'settle' ? 'settle_market' : 'void_market', { marketId: market.id, winningOptionId: selected?.id, reason: reason.trim() }); setConfirm(null)
        }}>Confirm {confirm === 'settle' ? 'settlement' : 'refund'}</button>
        <button className="button button--ghost" onClick={() => setConfirm(null)}>Cancel</button>
      </div>}
    </> : <button className="button" disabled={disabled || snapshot.game.periodStatus !== 'live'} onClick={() => onAction('open_next_goal', {})}>Open recovery Next Goal</button>}
    <Ladder title={`Q${snapshot.game.quarter} · top three`} entries={snapshot.quarterLadder.slice(0, 3)} />
    <details><summary>Full ladder and market audit</summary>
      <Ladder title="Quarter ladder" entries={snapshot.quarterLadder} />
      <Ladder title="Top Dog" entries={snapshot.topDogLadder} />
      {snapshot.markets.filter((m) => m.settledAt).map((m) => <div className="market-card" key={m.id}>
        <MarketSummaryCard market={m} serverNow={snapshot.serverNow} />
        <small>Audit: winning pool {m.settlement?.winningPoolBones} · losing pool {m.settlement?.losingPoolBones} · discarded dust {m.settlement?.dustBones} Bones</small>
      </div>)}
    </details>
  </section>
}
