import { beforeEach, describe, expect, it } from 'vitest'
import { demoEndQuarter, demoHostSnapshot, demoMarketAction, demoMutation, demoPause, demoPlaceBet,
  demoPlayerSnapshot, demoRecordScore, demoStartQuarter, demoUndo, resetDemo } from './demo'
const mutate = (action: () => void) => demoMutation(crypto.randomUUID(), action)
beforeEach(() => resetDemo())
describe('deterministic local Kennel loop', () => {
  it('increases one choice, settles, refunds successor spending and restores the original deadline on undo', () => {
    demoPlayerSnapshot('Alice:a'); demoPlayerSnapshot('Bob:b')
    mutate(() => demoStartQuarter(1))
    const market = demoHostSnapshot().activeMarket!
    demoPlaceBet('Alice:a', market.id, market.options[0].id, 50, 'a1')
    demoPlaceBet('Alice:a', market.id, market.options[0].id, 50, 'a1')
    demoPlaceBet('Bob:b', market.id, market.options[1].id, 100, 'b1')
    expect(() => demoPlaceBet('Alice:a', market.id, market.options[1].id, 25, 'a2')).toThrow(/selection/)
    mutate(() => demoRecordScore('home', 'goal'))
    expect(demoPlayerSnapshot('Alice:a').player.balance).toBe(1600)
    expect(demoPlayerSnapshot('Alice:a').quarterLadder.find((p) => p.isMe)?.profit).toBe(100)
    const successor = demoHostSnapshot().activeMarket!
    demoPlaceBet('Alice:a', successor.id, successor.options[1].id, 1500, 'a3')
    mutate(() => demoMarketAction('settle_market', { marketId: successor.id, winningOptionId: successor.options[1].id }))
    mutate(() => demoMarketAction('open_next_goal', {}))
    const later = demoHostSnapshot().activeMarket!
    demoPlaceBet('Alice:a', later.id, later.options[0].id, 1500, 'a4')
    mutate(demoUndo)
    expect(demoPlayerSnapshot('Alice:a').player.balance).toBe(1450)
    expect(demoPlayerSnapshot('Bob:b').player.balance).toBe(1400)
    expect(demoHostSnapshot().activeMarket?.locksAt).toBe(market.locksAt)
    expect(demoHostSnapshot().quarterLadder.every((p) => p.profit === 0)).toBe(true)
  })
  it('keeps score controls working during pause and freezes quarter standings at the siren', () => {
    demoPlayerSnapshot('Alice:a'); mutate(() => demoStartQuarter(1))
    const market = demoHostSnapshot().activeMarket!
    demoPlaceBet('Alice:a', market.id, market.options[0].id, 100, 'a1')
    mutate(() => demoPause(true))
    expect(() => demoPlaceBet('Alice:a', market.id, market.options[0].id, 25, 'a2')).toThrow(/paused/)
    mutate(() => demoRecordScore('away', 'behind'))
    expect(demoHostSnapshot().activeMarket?.id).toBe(market.id)
    mutate(() => demoRecordScore('away', 'goal'))
    expect(demoPlayerSnapshot('Alice:a').player.balance).toBe(1500)
    expect(demoHostSnapshot().recentMarket?.status).toBe('void')
    mutate(demoEndQuarter)
    const frozen = demoHostSnapshot().quarterResults[0]
    mutate(() => demoStartQuarter(2))
    expect(demoHostSnapshot().quarterResults[0]).toEqual(frozen)
    expect(demoHostSnapshot().game.canUndo).toBe(false)
  })
})
