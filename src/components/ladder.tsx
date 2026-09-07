import type { LadderEntry } from '../types'
export const signedBones = (value: number) => `${value > 0 ? '+' : ''}${value.toLocaleString()}`
export function Ladder({ title, entries, playerId }: { title: string; entries: LadderEntry[]; playerId?: string }) {
  return <section className="ladder-card"><h2>{title}</h2>
    <p className="muted-note">Net profit · Bones</p>
    {entries.length ? <ol className="ladder-list">{entries.map((entry) =>
      <li key={entry.playerId} className={entry.isMe || entry.playerId === playerId ? 'ladder-me' : ''}>
        <span>{entry.rank}</span><strong>{entry.nickname}{(entry.isMe || entry.playerId === playerId) && ' (you)'}</strong>
        <b>{signedBones(entry.profit)}</b>
      </li>)}</ol> : <p>No settled predictions yet.</p>}
  </section>
}
