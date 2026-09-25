import { useState } from 'react'
import type { KennelHostAction } from '../lib/api'
import type { HostSnapshot, StudsMatchup } from '../types'
import { MarketSummaryCard, optionLabel, statLabel } from './market-card'

type OnAction = (label: string, action: KennelHostAction, payload: Record<string, unknown>) => void
const whole = (value: string) => /^\d{1,3}$/.test(value.trim()) ? Number(value) : null

/** The quarter whose Studs can open now: Q1 pre-match, or the next quarter during a break. */
function upcomingQuarter(snapshot: HostSnapshot) {
  if (snapshot.game.periodStatus === 'pre_match') return 1
  if (snapshot.game.periodStatus === 'break') return snapshot.game.quarter + 1
  return null
}

export function HostStuds({ snapshot, disabled, onAction }: { snapshot: HostSnapshot; disabled: boolean; onAction: OnAction }) {
  const upcoming = upcomingQuarter(snapshot)
  const unopened = snapshot.studsMatchups.filter((m) => m.quarter === upcoming && !m.marketId).length
  const pending = snapshot.studsMatchups.filter((m) => m.marketId && !m.resolvedAt
    && snapshot.quarterResults.some((r) => r.quarter === m.quarter))
  return <section className="host-card">
    <div className="host-card__heading">
      <div><span className="eyebrow">Break game</span><h2>Studs v Spuds</h2></div>
      {upcoming && unopened > 0 && <button className="button button--gold" disabled={disabled}
        onClick={() => onAction('open studs', 'open_studs', {})}>Open Q{upcoming} Studs ({unopened})</button>}
    </div>
    <p>Each quarter's matchups open in the break before it (Q1 before the match) and lock at the bounce. The siren opens
      the next quarter's matchups on its own. At each siren, enter <strong>cumulative game totals</strong>; the server subtracts the baselines.</p>
    {pending.length > 0 && <p className="studs-reading" role="status">Awaiting results: {pending.map((m) => `Q${m.quarter} ${m.athleteAName} v ${m.athleteBName}`).join(', ')}</p>}
    {[1, 2, 3, 4].map((quarter) => <StudsQuarter key={quarter} quarter={quarter} snapshot={snapshot} disabled={disabled} onAction={onAction} />)}
    <AthleteForm disabled={disabled} onAction={onAction} />
  </section>
}

function StudsQuarter({ quarter, snapshot, disabled, onAction }: { quarter: number; snapshot: HostSnapshot; disabled: boolean; onAction: OnAction }) {
  const matchups = snapshot.studsMatchups.filter((m) => m.quarter === quarter)
  const [slot, setSlot] = useState('')
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  const [stat, setStat] = useState('disposals')
  const [round, setRound] = useState(matchups[0]?.roundLabel ?? '')
  const sirenSounded = snapshot.quarterResults.some((r) => r.quarter === quarter)
  const freeSlots = [1, 2, 3].filter((s) => !matchups.some((m) => m.slot === s && m.marketId))
  return <details className="studs-quarter" open={matchups.some((m) => m.marketId && !m.resolvedAt)}>
    <summary>Q{quarter} · {matchups[0]?.roundLabel ?? 'No matchups'} · {matchups.length} matchup{matchups.length === 1 ? '' : 's'}</summary>
    {matchups.map((m) => <StudsRow key={m.id} matchup={m} sirenSounded={sirenSounded} disabled={disabled} onAction={onAction} />)}
    {freeSlots.length > 0 && <div className="studs-config">
      <label>Slot<select value={slot} disabled={disabled} onChange={(e) => setSlot(e.target.value)}>
        <option value="">Choose</option>{freeSlots.map((s) => <option key={s} value={s}>{s}</option>)}</select></label>
      <label>Round<input value={round} maxLength={40} disabled={disabled} placeholder="e.g. Ruck Round" onChange={(e) => setRound(e.target.value)} /></label>
      <label>Stat<select value={stat} disabled={disabled} onChange={(e) => setStat(e.target.value)}>
        <option value="disposals">Disposals</option><option value="hitouts">Hit-outs</option></select></label>
      <label>Stud (A)<select value={a} disabled={disabled} onChange={(e) => setA(e.target.value)}>
        <option value="">Choose</option>{snapshot.athletes.map((x) => <option key={x.id} value={x.id}>{x.name}{x.team ? ` (${x.team})` : ''}</option>)}</select></label>
      <label>Spud (B)<select value={b} disabled={disabled} onChange={(e) => setB(e.target.value)}>
        <option value="">Choose</option>{snapshot.athletes.map((x) => <option key={x.id} value={x.id}>{x.name}{x.team ? ` (${x.team})` : ''}</option>)}</select></label>
      <button className="button" disabled={disabled || !slot || !a || !b || a === b || !round.trim()}
        onClick={() => onAction('save matchup', 'configure_studs_matchup', { quarter, slot: Number(slot), roundLabel: round.trim(), stat, athleteAId: a, athleteBId: b })}>
        Save matchup</button>
    </div>}
  </details>
}

function StudsRow({ matchup: m, sirenSounded, disabled, onAction }: { matchup: StudsMatchup; sirenSounded: boolean; disabled: boolean; onAction: OnAction }) {
  const [baselineA, setBaselineA] = useState(m.baselineA?.toString() ?? '')
  const [baselineB, setBaselineB] = useState(m.baselineB?.toString() ?? '')
  const [endingA, setEndingA] = useState('')
  const [endingB, setEndingB] = useState('')
  const [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState<'settle' | 'void' | null>(null)
  const name = (label: string, team: string | null) => team ? `${label} (${team})` : label
  const status = m.resolvedAt ? (m.marketStatus === 'void' ? 'Refunded' : 'Settled') : m.marketStatus ?? 'Not open yet'
  const ea = whole(endingA); const eb = whole(endingB)
  const ready = m.baselineA !== null && m.baselineB !== null && ea !== null && eb !== null
  const qa = ready ? ea! - m.baselineA! : null
  const qb = ready ? eb! - m.baselineB! : null
  const invalid = qa !== null && qb !== null && (qa < 0 || qb < 0)
  const preview = qa === null || qb === null || invalid ? null
    : qa === qb ? `Level at ${qa} each: every stake is refunded.` : `${qa > qb ? m.athleteAName : m.athleteBName} wins the quarter, ${Math.max(qa, qb)} to ${Math.min(qa, qb)}.`
  return <div className="studs-row">
    <p><strong>{m.slot}. {name(m.athleteAName, m.athleteATeam)} v {name(m.athleteBName, m.athleteBTeam)}</strong> · most {statLabel(m.stat)} · {status}</p>
    {m.resolvedAt && m.endingA !== null && <p className="muted-note">Cumulative {m.endingA} and {m.endingB} from baselines {m.baselineA} and {m.baselineB}: {m.endingA - m.baselineA!} v {m.endingB! - m.baselineB!} this quarter.</p>}
    {!m.marketId && <button className="button button--ghost" disabled={disabled}
      onClick={() => onAction('remove matchup', 'configure_studs_matchup', { quarter: m.quarter, slot: m.slot, athleteAId: null })}>Remove</button>}
    {!m.resolvedAt && m.quarter > 1 && <div className="studs-inputs">
      <span className="muted-note">Baselines: cumulative {statLabel(m.stat)} at the Q{m.quarter - 1} siren. Look them up during that break.</span>
      <label>{m.athleteAName}<input inputMode="numeric" value={baselineA} disabled={disabled} onChange={(e) => setBaselineA(e.target.value)} /></label>
      <label>{m.athleteBName}<input inputMode="numeric" value={baselineB} disabled={disabled} onChange={(e) => setBaselineB(e.target.value)} /></label>
      <button className="button button--ghost" disabled={disabled || whole(baselineA) === null || whole(baselineB) === null}
        onClick={() => onAction('save baselines', 'set_studs_baselines', { matchupId: m.id, baselineA: whole(baselineA), baselineB: whole(baselineB) })}>
        {m.baselineA === null ? 'Save baselines' : `Update baselines (now ${m.baselineA} / ${m.baselineB})`}</button>
    </div>}
    {m.marketId && !m.resolvedAt && sirenSounded && <div className="studs-inputs">
      <span className="muted-note">Cumulative {statLabel(m.stat)} at the Q{m.quarter} siren (game totals, not this quarter's).</span>
      <label>{m.athleteAName}<input inputMode="numeric" value={endingA} disabled={disabled} onChange={(e) => { setEndingA(e.target.value); setConfirm(null) }} /></label>
      <label>{m.athleteBName}<input inputMode="numeric" value={endingB} disabled={disabled} onChange={(e) => { setEndingB(e.target.value); setConfirm(null) }} /></label>
      {m.baselineA === null && <p className="form-error">Enter this matchup's baselines first.</p>}
      {invalid && <p className="form-error">A cumulative total cannot be lower than its baseline.</p>}
      {preview && <p className="studs-reading">This quarter: {m.athleteAName} {qa} · {m.athleteBName} {qb}. {preview}</p>}
      <button className="button" disabled={disabled || !preview} onClick={() => setConfirm('settle')}>Review result</button>
    </div>}
    {m.marketId && !m.resolvedAt && <div className="studs-inputs">
      <label>Refund reason<input maxLength={200} value={reason} disabled={disabled} onChange={(e) => { setReason(e.target.value); setConfirm(null) }} /></label>
      <button className="button button--danger-outline" disabled={disabled || !reason.trim()} onClick={() => setConfirm('void')}>Review void and refund</button>
    </div>}
    {confirm && <div className="confirmation" role="group" aria-label="Confirm Studs result">
      <p>{confirm === 'settle' ? `Pay out: ${preview}` : `Refund every stake on this matchup? Reason: ${reason}`}</p>
      <button className="button button--gold" disabled={disabled} onClick={() => {
        if (confirm === 'settle') onAction('settle studs', 'settle_studs', { matchupId: m.id, endingA: ea, endingB: eb })
        else onAction('void studs', 'void_studs', { matchupId: m.id, reason: reason.trim() })
        setConfirm(null)
      }}>Confirm {confirm === 'settle' ? 'result' : 'refund'}</button>
      <button className="button button--ghost" onClick={() => setConfirm(null)}>Cancel</button>
    </div>}
  </div>
}

function AthleteForm({ disabled, onAction }: { disabled: boolean; onAction: OnAction }) {
  const [name, setName] = useState('')
  const [team, setTeam] = useState('')
  return <details><summary>Add an athlete</summary>
    <div className="studs-config">
      <label>Name<input value={name} maxLength={80} disabled={disabled} onChange={(e) => setName(e.target.value)} /></label>
      <label>Team<input value={team} maxLength={40} disabled={disabled} placeholder="FRE or BRI" onChange={(e) => setTeam(e.target.value)} /></label>
      <button className="button" disabled={disabled || !name.trim()} onClick={() => {
        onAction('add athlete', 'ensure_athletes', { athletes: [{ name: name.trim(), team: team.trim() }] }); setName('')
      }}>Add athlete</button>
    </div>
  </details>
}

export function HostFutures({ snapshot, disabled, onAction }: { snapshot: HostSnapshot; disabled: boolean; onAction: OnAction }) {
  const winner = snapshot.futures.find((m) => m.type === 'futures_winner')
  const norm = snapshot.futures.find((m) => m.type === 'futures_norm_smith')
  const configuredIds = new Set(norm?.options.map((o) => o.optionKey.replace('athlete:', '')) ?? [])
  const [candidates, setCandidates] = useState<string[]>(() => snapshot.athletes.filter((a) => configuredIds.has(a.id)).map((a) => a.id))
  const [normWinner, setNormWinner] = useState('')
  const [reason, setReason] = useState('')
  const [confirm, setConfirm] = useState<'match' | 'norm' | { voidId: string } | null>(null)
  const preMatch = snapshot.game.periodStatus === 'pre_match'
  const final = snapshot.game.periodStatus === 'final'
  const drafts = snapshot.futures.length === 0 || snapshot.futures.some((m) => m.status === 'draft')
  const selectedNorm = norm?.options.find((o) => o.id === normWinner)
  const scoreWinner = snapshot.game.homePoints === snapshot.game.awayPoints ? null
    : snapshot.game.homePoints > snapshot.game.awayPoints ? snapshot.event.homeTeam : snapshot.event.awayTeam
  return <section className="host-card">
    <span className="eyebrow">Settle at full time</span><h2>Futures</h2>
    <p>Match winner and Norm Smith open before the match, lock at the Q1 bounce, and count toward Top Dog only. Each is capped at 200 Bones a guest.</p>
    {preMatch && drafts && <>
      <fieldset className="candidate-list" disabled={disabled}>
        <legend>Norm Smith candidates ({candidates.length}), plus “Any other player”</legend>
        {snapshot.athletes.map((a) => <label key={a.id} className="candidate">
          <input type="checkbox" checked={candidates.includes(a.id)}
            onChange={(e) => setCandidates((list) => e.target.checked ? [...list, a.id] : list.filter((id) => id !== a.id))} />
          {a.name}{a.team ? ` (${a.team})` : ''}</label>)}
      </fieldset>
      <div className="inline-actions">
        <button className="button" disabled={disabled || candidates.length === 0}
          onClick={() => onAction('save futures', 'configure_futures', { candidateIds: candidates, matchMaxStake: 200, normSmithMaxStake: 200 })}>
          Save Futures</button>
        <button className="button button--gold" disabled={disabled || !winner || !norm}
          onClick={() => onAction('open futures', 'open_futures', {})}>Open both Futures</button>
      </div>
    </>}
    {[winner, norm].map((m) => m && <div className="market-card" key={m.id}>
      <MarketSummaryCard market={m} serverNow={snapshot.serverNow} />
      {m.status === 'draft' && <small>Draft: guests cannot see this yet.</small>}
      {!m.settledAt && m.status !== 'draft' && <button className="button button--danger-outline" disabled={disabled || !reason.trim()}
        onClick={() => setConfirm({ voidId: m.id })}>Review void and refund</button>}
    </div>)}
    {snapshot.futures.some((m) => !m.settledAt && m.status !== 'draft') &&
      <label>Refund reason (for a void)<input maxLength={200} value={reason} disabled={disabled} onChange={(e) => setReason(e.target.value)} /></label>}
    {final && winner && !winner.settledAt && <button className="button button--gold" disabled={disabled} onClick={() => setConfirm('match')}>
      Settle match winner from the final score</button>}
    {final && norm && !norm.settledAt && <div className="team-inputs">
      <label>Norm Smith medallist<select value={normWinner} disabled={disabled} onChange={(e) => { setNormWinner(e.target.value); setConfirm(null) }}>
        <option value="">Choose</option>{norm.options.map((o) => <option key={o.id} value={o.id}>{optionLabel(o)}</option>)}</select></label>
      <button className="button" disabled={disabled || !selectedNorm} onClick={() => setConfirm('norm')}>Review Norm Smith</button>
    </div>}
    {!final && winner && !winner.settledAt && winner.status !== 'draft' && <small>Settle both Futures after sounding the Q4 siren.</small>}
    {confirm && <div className="confirmation" role="group" aria-label="Confirm Futures result">
      <p>{confirm === 'match'
        ? (scoreWinner ? `Final score ${snapshot.game.homePoints}–${snapshot.game.awayPoints}: pay ${scoreWinner} backers.` : 'The final score is level: every stake is refunded.')
        : confirm === 'norm' ? `Pay out Norm Smith to ${selectedNorm ? optionLabel(selectedNorm) : ''}.`
          : `Refund every stake on this Future? Reason: ${reason}`}</p>
      <button className="button button--gold" disabled={disabled} onClick={() => {
        if (confirm === 'match') onAction('settle match winner', 'settle_match_future', {})
        else if (confirm === 'norm') onAction('settle norm smith', 'settle_norm_smith', { winningOptionId: normWinner })
        else onAction('void future', 'void_future', { marketId: confirm.voidId, reason: reason.trim() })
        setConfirm(null)
      }}>Confirm</button>
      <button className="button button--ghost" onClick={() => setConfirm(null)}>Cancel</button>
    </div>}
  </section>
}
