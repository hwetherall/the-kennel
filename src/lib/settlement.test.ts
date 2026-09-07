import { describe, expect, it } from 'vitest'
import { settleReferenceMarket, type ReferenceBet } from './settlement'

const settledAt = '2026-09-26T05:00:00Z'
const bet = (id: string, optionId: string, stake: number): ReferenceBet => ({ id, optionId, stake })
const settle = (bets: ReferenceBet[], winner = 'home') => settleReferenceMarket({
  optionIds: ['home', 'away'], bets, settlement: null,
}, winner, settledAt)

describe('Phase 2 settlement specification', () => {
  it('pays 150 and profits 100 for 50 of a 500 winning pool against 1,000', () => {
    const { market, credits } = settle([bet('a', 'home', 50), bet('b', 'home', 450), bet('c', 'away', 1_000)])
    expect(market.settlement).toMatchObject({
      status: 'settled', winningOptionId: 'home', winningPoolBones: 500,
      losingPoolBones: 1_000, dustBones: 0, settledAt,
    })
    expect(market.settlement?.bets).toEqual([
      { ...bet('a', 'home', 50), payout: 150, profit: 100 },
      { ...bet('b', 'home', 450), payout: 1_350, profit: 900 },
      { ...bet('c', 'away', 1_000), payout: 0, profit: -1_000 },
    ])
    expect(credits).toEqual([
      { betId: 'a', kind: 'payout', amount: 150 },
      { betId: 'b', kind: 'payout', amount: 1_350 },
    ])
  })

  it('voids and refunds everyone when nobody backed the scorer', () => {
    const { market, credits } = settle([bet('a', 'away', 25), bet('b', 'away', 100)])
    expect(market.settlement).toMatchObject({
      status: 'void', winningOptionId: null, winningPoolBones: 0, losingPoolBones: 125, dustBones: 0,
    })
    expect(market.settlement?.bets.map(({ payout, profit }) => ({ payout, profit })))
      .toEqual([{ payout: 25, profit: 0 }, { payout: 100, profit: 0 }])
    expect(credits).toEqual([
      { betId: 'a', kind: 'refund', amount: 25 },
      { betId: 'b', kind: 'refund', amount: 100 },
    ])
  })

  it('returns stakes with zero profit for a winning one-sided pool', () => {
    const { market } = settle([bet('a', 'home', 25), bet('b', 'home', 100)])
    expect(market.settlement?.status).toBe('settled')
    expect(market.settlement?.bets.map(({ payout, profit }) => ({ payout, profit })))
      .toEqual([{ payout: 25, profit: 0 }, { payout: 100, profit: 0 }])
  })

  it('returns a single backer’s stake', () => {
    expect(settle([bet('a', 'home', 50)]).market.settlement?.bets[0])
      .toMatchObject({ payout: 50, profit: 0 })
  })

  it('voids an empty market without any ledger credits', () => {
    const { market, credits } = settle([])
    expect(market.settlement).toMatchObject({ status: 'void', bets: [], dustBones: 0 })
    expect(credits).toEqual([])
  })

  it('floors uneven shares and audits the undistributed remainder', () => {
    const { market } = settle([
      bet('a', 'home', 2), bet('b', 'home', 3), bet('c', 'home', 6), bet('d', 'away', 7),
    ])
    expect(market.settlement?.bets.map(({ payout }) => payout)).toEqual([3, 4, 9, 0])
    expect(market.settlement?.dustBones).toBe(2)
  })

  it.each(['home', 'away'])('issues no additional credits on a repeated %s settlement', (winner) => {
    const first = settle([bet('a', 'home', 50), bet('b', 'away', 100)])
    const second = settleReferenceMarket(first.market, winner, '2026-09-26T05:01:00Z')
    expect(second.market).toBe(first.market)
    expect(second.credits).toEqual([])
  })

  it('does not refund a void market twice', () => {
    const first = settle([bet('a', 'away', 50)])
    expect(settleReferenceMarket(first.market, 'home', settledAt).credits).toEqual([])
  })

  it('conserves the pool and never distributes more than the losing pool', () => {
    for (let a = 1; a <= 15; a += 1) {
      for (let b = 1; b <= 15; b += 1) {
        for (let losing = 0; losing <= 15; losing += 1) {
          const bets = [bet('a', 'home', a), bet('b', 'home', b)]
          if (losing > 0) bets.push(bet('c', 'away', losing))
          const result = settle(bets).market.settlement!
          const payouts = result.bets.reduce((sum, entry) => sum + entry.payout, 0)
          const profit = result.bets.reduce((sum, entry) => sum + entry.profit, 0)
          expect(payouts + result.dustBones).toBe(a + b + losing)
          expect(payouts - a - b).toBeLessThanOrEqual(losing)
          expect(profit + result.dustBones).toBe(0)
          expect(result.dustBones).toBeGreaterThanOrEqual(0)
        }
      }
    }
  })

  it('uses exact integer arithmetic even when the intermediate product exceeds JS safe integers', () => {
    const { market } = settle([
      bet('a', 'home', 1_000_000_001), bet('b', 'home', 1), bet('c', 'away', 1_000_000_001),
    ])
    expect(market.settlement?.bets.map(({ payout }) => payout)).toEqual([2_000_000_001, 1, 0])
    expect(market.settlement?.dustBones).toBe(1)
  })

  it.each([0, -1, 0.5, NaN, Infinity, 2_147_483_648])('rejects invalid stake %s', (stake) => {
    expect(() => settle([bet('a', 'home', stake)])).toThrow(/positive PostgreSQL integer/)
  })

  it('rejects an option from another market', () => {
    expect(() => settle([bet('a', 'foreign', 25)])).toThrow(/option/)
    expect(() => settle([bet('a', 'home', 25)], 'foreign')).toThrow(/option/)
  })

  it('rejects duplicate bet IDs', () => {
    expect(() => settle([bet('a', 'home', 25), bet('a', 'away', 25)])).toThrow(/Duplicate bet/)
  })

  it('rejects pools and payouts that cannot fit the database integer fields', () => {
    expect(() => settle([bet('a', 'home', 2_147_483_647), bet('b', 'home', 1)])).toThrow(/range/)
    expect(() => settle([bet('a', 'home', 2_147_483_647), bet('b', 'away', 1)])).toThrow(/range/)
  })
})
