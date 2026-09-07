/**
 * Executable reference for the Postgres settlement transaction.
 * Test/documentation use only: browser balances and pools must come from the API.
 * This models repeat settlement; database locks/receipts need integration tests.
 */
export interface ReferenceBet {
  readonly id: string
  readonly optionId: string
  readonly stake: number
}

export interface ReferenceSettlement {
  readonly status: 'settled' | 'void'
  readonly winningOptionId: string | null
  readonly settledAt: string
  readonly winningPoolBones: number
  readonly losingPoolBones: number
  readonly dustBones: number
  readonly bets: readonly (ReferenceBet & { readonly payout: number; readonly profit: number })[]
}

export interface ReferenceMarket {
  readonly optionIds: readonly string[]
  readonly bets: readonly ReferenceBet[]
  readonly settlement: ReferenceSettlement | null
}

export interface ReferenceCredit {
  readonly betId: string
  readonly kind: 'payout' | 'refund'
  readonly amount: number
}

const POSTGRES_INT_MAX = 2_147_483_647n

function databaseInteger(value: bigint): number {
  if (value < 0n || value > POSTGRES_INT_MAX) {
    throw new Error('Settlement exceeds the PostgreSQL integer range')
  }
  return Number(value)
}

export function settleReferenceMarket(
  market: ReferenceMarket,
  winningOptionId: string,
  settledAt: string,
): { market: ReferenceMarket; credits: readonly ReferenceCredit[] } {
  // A persisted settlement is authoritative, even when a retry names another winner.
  if (market.settlement !== null) return { market, credits: [] }
  if (!market.optionIds.includes(winningOptionId)) throw new Error('Unknown winning option')
  if (!Number.isFinite(Date.parse(settledAt))) throw new Error('A settlement timestamp is required')

  let winningPool = 0n
  let losingPool = 0n
  const seen = new Set<string>()
  for (const bet of market.bets) {
    if (seen.has(bet.id)) throw new Error('Duplicate bet ID')
    seen.add(bet.id)
    if (!market.optionIds.includes(bet.optionId)) throw new Error('Unknown bet option')
    if (!Number.isInteger(bet.stake) || bet.stake <= 0 || bet.stake > Number(POSTGRES_INT_MAX)) {
      throw new Error('Stake must be a positive PostgreSQL integer')
    }
    if (bet.optionId === winningOptionId) winningPool += BigInt(bet.stake)
    else losingPool += BigInt(bet.stake)
  }

  const winningPoolBones = databaseInteger(winningPool)
  const losingPoolBones = databaseInteger(losingPool)
  const voided = winningPool === 0n
  let distributedProfit = 0n
  const credits: ReferenceCredit[] = []
  const bets = market.bets.map((bet) => {
    let payout = 0
    if (voided) {
      payout = bet.stake
    } else if (bet.optionId === winningOptionId) {
      // Cast before multiplication in SQL too; integer multiplication can overflow.
      const profit = BigInt(bet.stake) * losingPool / winningPool
      payout = databaseInteger(BigInt(bet.stake) + profit)
      distributedProfit += profit
    }
    if (payout > 0) credits.push({ betId: bet.id, kind: voided ? 'refund' : 'payout', amount: payout })
    return { ...bet, payout, profit: payout - bet.stake }
  })

  return {
    market: {
      ...market,
      settlement: {
        status: voided ? 'void' : 'settled',
        winningOptionId: voided ? null : winningOptionId,
        settledAt,
        winningPoolBones,
        losingPoolBones,
        dustBones: voided ? 0 : databaseInteger(losingPool - distributedProfit),
        bets,
      },
    },
    credits,
  }
}
