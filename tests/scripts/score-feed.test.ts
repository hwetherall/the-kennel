// @vitest-environment node
import { expect, it } from 'vitest'
// @ts-expect-error plain ESM script without type declarations
import { parseSseChunk, readingFrom } from '../../scripts/score-feed-parse.mjs'

const score = 'event:score\nid:1\ndata:{"gameid":38729,"type":"goal","side":"hteam","team":6,"complete":12,"timestr":"Q1 14:02","score":{"hgoals":2,"hbehinds":1,"hscore":13,"agoals":1,"abehinds":3,"ascore":9}}\n\n'

it('splits complete events and keeps a partial one for the next chunk', () => {
  const { events, rest } = parseSseChunk(`retry:2000\n\nevent:message\ndata:"Welcome"\n\n${score}event:score\ndata:{"sco`)
  expect(events.map((e: { event: string }) => e.event)).toEqual(['message', 'score'])
  expect(rest).toBe('event:score\ndata:{"sco')
})

it('reads the running score from a score event, and nothing from a greeting', () => {
  const { events } = parseSseChunk(score.replace(/\n/g, '\r\n'))
  expect(readingFrom(events[0].data, events[0].event)).toEqual({ hgoals: 2, hbehinds: 1, agoals: 1, abehinds: 3, timestr: 'Q1 14:02', complete: 12 })
  expect(readingFrom('"Welcome to the TEST channel"', 'message')).toBeNull()
})

it('reads a Standard API game object, and skips one with no score yet', () => {
  expect(readingFrom({ id: 38729, hgoals: 0, hbehinds: 0, agoals: 0, abehinds: 0, complete: 0, timestr: null })).toMatchObject({ hgoals: 0, complete: 0 })
  expect(readingFrom({ id: 38729, hgoals: null, hbehinds: null, agoals: null, abehinds: null })).toBeNull()
})
