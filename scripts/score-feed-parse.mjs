// Pure helpers for scripts/score-feed.mjs, kept separate so they can be tested.

/** Splits complete SSE events off a text buffer; returns them and the unfinished remainder. */
export function parseSseChunk(buffer) {
  const blocks = buffer.replace(/\r\n/g, '\n').split('\n\n')
  const rest = blocks.pop() ?? ''
  const events = blocks.map((block) => {
    let event = 'message'
    const data = []
    for (const line of block.split('\n')) {
      if (line.startsWith('event:')) event = line.slice(6).trim()
      else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''))
    }
    return { event, data: data.join('\n') }
  }).filter((event) => event.data)
  return { events, rest }
}

/**
 * A running-score reading from a Squiggle score event, game object, or games list
 * entry; null for anything that carries no score.
 */
export function readingFrom(payload, event = 'game') {
  let value = payload
  if (typeof value === 'string') {
    try { value = JSON.parse(value) } catch { return null }
  }
  if (!value || typeof value !== 'object' || !['score', 'game', 'message'].includes(event)) return null
  const score = value.score && typeof value.score === 'object' ? value.score : value
  const fields = ['hgoals', 'hbehinds', 'agoals', 'abehinds']
  if (!fields.every((field) => Number.isInteger(Number(score[field])) && score[field] !== null && score[field] !== '')) return null
  return {
    hgoals: Number(score.hgoals), hbehinds: Number(score.hbehinds),
    agoals: Number(score.agoals), abehinds: Number(score.abehinds),
    timestr: typeof value.timestr === 'string' ? value.timestr : null,
    complete: Number.isInteger(value.complete) ? value.complete : null,
  }
}
