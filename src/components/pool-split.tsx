import type { MarketSummary } from '../types'

export function PoolSplit({ market }: { market: MarketSummary }) {
  return <div className="pool-split" aria-label="Pool split">
    {market.options.map((option) => {
      const percent = market.totalPoolBones ? Math.round(option.poolBones / market.totalPoolBones * 100) : 0
      return <div key={option.id} className="pool-option">
        <div><strong>{option.label}</strong><span>{option.poolBones.toLocaleString()} Bones · {percent}%</span></div>
        <progress max={100} value={percent} aria-label={`${option.label} pool share`} />
      </div>
    })}
    <small>{market.totalPoolBones.toLocaleString()} Bones in pool · {market.betCount} backers</small>
  </div>
}
