import { describe, expect, test } from 'claude-code/testing'

import {
  agentAlerts,
  agentMissToast,
  agentSegment,
  asBounds,
  classifyStep,
  effectiveTtl,
  formatUsd,
  joinSegments,
  pruneTracks,
  gateDecision,
  gateQuestion,
  handoffPrompt,
  isCrewPrompt,
  learnTtl,
  noBounds,
  observeStep,
  priceFor,
  segmentFile,
  segmentFor,
} from '../hooks/rules'
import type { AgentTrack, LastResponse, ListedAgent } from '../types'

const MINUTE = 60_000

function cents(usd: number | undefined) {
  return Math.round((usd ?? NaN) * 100) / 100
}
const OPUS = 'claude-opus-5-5'

function usage(read: number, write: number, input = 0, model = OPUS) {
  return { input_tokens: input, cache_read_input_tokens: read, cache_creation_input_tokens: write, output_tokens: 10, model }
}

describe('priceFor', () => {
  test('matches model ids by prefix, past a dated or vendor-prefixed id', () => {
    expect(priceFor('claude-opus-5-5', 1000).write1h).toBe(8)
    expect(priceFor('claude-sonnet-5-5-20260901', 1000).input).toBe(2)
    expect(priceFor('us.anthropic.claude-fable-5-1-v1:0', 1000).read).toBe(0.25)
    expect(priceFor('claude-haiku-5-5', 1000).write5m).toBe(0.125)
  })

  test('applies the Haiku long-context tier above 100k tokens', () => {
    expect(priceFor('claude-haiku-5-5', 100_000).input).toBe(0.1)
    expect(priceFor('claude-haiku-5-5', 100_001).input).toBe(0.5)
    expect(priceFor('claude-haiku-5-5', 200_000).write1h).toBe(1)
    expect(priceFor('claude-opus-5-5', 900_000).input).toBe(4)
  })

  test('falls back to Opus 5.5 for an unknown model', () => {
    expect(priceFor('some-gateway-model', 1000)).toEqual(priceFor(OPUS, 1000))
  })
})

describe('classifyStep', () => {
  test('warm when the cache served at least half the previous context', () => {
    expect(classifyStep(100_000, usage(50_000, 2_000))).toBe('warm')
  })

  test('cold when most was written and under half read', () => {
    expect(classifyStep(100_000, usage(9_000, 95_000))).toBe('cold')
  })

  test('cold when only a shared system prefix was still cached (a resumed subagent)', () => {
    expect(classifyStep(148_000, usage(27_886, 121_000))).toBe('cold')
  })

  test('neither when little was written, or without a previous context', () => {
    expect(classifyStep(100_000, usage(20_000, 30_000))).toBeNull()
    expect(classifyStep(100_000, usage(0, 30_000))).toBeNull()
    expect(classifyStep(0, usage(0, 30_000))).toBeNull()
  })
})

describe('ttl bounds', () => {
  test('a warm gap raises the TTL above the default', () => {
    const b = learnTtl(noBounds, 'warm', 90 * MINUTE)
    expect(effectiveTtl(b, 60 * MINUTE)).toBe(90 * MINUTE)
    expect(effectiveTtl(learnTtl(b, 'warm', 70 * MINUTE), 60 * MINUTE)).toBe(90 * MINUTE)
  })

  test('a cold gap caps it, keeping the shortest', () => {
    const b = learnTtl(learnTtl(noBounds, 'cold', 20 * MINUTE), 'cold', 30 * MINUTE)
    expect(b.coldMinMs).toBe(20 * MINUTE)
    expect(effectiveTtl(b, 60 * MINUTE)).toBe(20 * MINUTE)
  })

  test('an observation that contradicts the bounds resets them', () => {
    const coldAt10 = learnTtl(noBounds, 'cold', 10 * MINUTE)
    expect(learnTtl(coldAt10, 'warm', 40 * MINUTE)).toEqual({ warmMaxMs: 40 * MINUTE, coldMinMs: null })
    const warmAt50 = learnTtl(noBounds, 'warm', 50 * MINUTE)
    expect(learnTtl(warmAt50, 'cold', 30 * MINUTE)).toEqual({ warmMaxMs: null, coldMinMs: 30 * MINUTE })
  })

  test('reads stored bounds defensively', () => {
    expect(asBounds(undefined)).toEqual(noBounds)
    expect(asBounds({ warmMaxMs: 'x', coldMinMs: 5 })).toEqual({ warmMaxMs: null, coldMinMs: 5 })
  })
})

describe('observeStep', () => {
  const prev: LastResponse = { at: 0, ctx: 380_000, model: OPUS }
  const base = { prev, bounds: noBounds, defaultTtlMs: 60 * MINUTE }

  test('records the context the step was answered over', () => {
    const o = observeStep({ ...base, prev: null, startedAt: 0, now: 5, usage: usage(1_000, 2_000, 300) })
    expect(o?.last).toEqual({ at: 5, ctx: 3_300, model: OPUS })
    expect(o?.miss).toBeNull()
  })

  test('a cold step after a long gap is a miss priced at the write rate', () => {
    const o = observeStep({ ...base, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 380_000) })
    expect(o?.bounds.coldMinMs).toBe(72 * MINUTE)
    expect(o?.miss).toMatchObject({ gapMs: 72 * MINUTE, tokens: 380_000 })
    expect(cents(o?.miss?.usd)).toBe(3.04)
  })

  test('a cold step soon after the last response teaches nothing', () => {
    const o = observeStep({ ...base, startedAt: 2 * MINUTE, now: 3 * MINUTE, usage: usage(0, 380_000) })
    expect(o?.bounds).toEqual(noBounds)
    expect(o?.miss).toBeNull()
  })

  test('a model switch teaches nothing', () => {
    const o = observeStep({ ...base, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 380_000, 0, 'claude-sonnet-5-5') })
    expect(o?.bounds).toEqual(noBounds)
    expect(o?.miss).toBeNull()
  })

  test('a step that reports no context is not an observation', () => {
    expect(observeStep({ ...base, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 0) })).toBeNull()
  })

  test('a small cold rewrite is learnt from but not reported', () => {
    const small = { at: 0, ctx: 30_000, model: OPUS }
    const o = observeStep({ ...base, prev: small, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 30_000) })
    expect(o?.bounds.coldMinMs).toBe(72 * MINUTE)
    expect(o?.miss).toBeNull()
  })
})

describe('gateDecision', () => {
  const last: LastResponse = { at: 0, ctx: 380_000, model: OPUS }

  test('stays quiet before the TTL, without a previous response, or without a live context size', () => {
    expect(gateDecision(last, 380_000, 59 * MINUTE, 60 * MINUTE, 1)).toBeNull()
    expect(gateDecision(null, 380_000, 600 * MINUTE, 60 * MINUTE, 1)).toBeNull()
    expect(gateDecision(last, undefined, 600 * MINUTE, 60 * MINUTE, 1)).toBeNull()
  })

  test('asks past the TTL when the re-write costs at least the threshold', () => {
    const gate = gateDecision(last, 380_000, 72 * MINUTE, 60 * MINUTE, 1)
    expect(gate).toMatchObject({ idleMs: 72 * MINUTE, tokens: 380_000 })
    expect(Object.keys(gate ?? {}).sort()).toEqual(['idleMs', 'rewriteUsd', 'tokens'])
    expect(cents(gate?.rewriteUsd)).toBe(3.04)
  })

  test('prices the live context size, not the remembered one', () => {
    expect(gateDecision(last, 20_000, 72 * MINUTE, 60 * MINUTE, 1)).toBeNull()
    expect(gateDecision(last, 20_000, 72 * MINUTE, 60 * MINUTE, 0)).toMatchObject({ tokens: 20_000 })
  })

  test('stays quiet when the re-write is under the threshold', () => {
    expect(gateDecision(last, 100_000, 72 * MINUTE, 60 * MINUTE, 1)).toBeNull()
    expect(gateDecision(last, 100_000, 72 * MINUTE, 60 * MINUTE, 0)).not.toBeNull()
  })
})

describe('isCrewPrompt', () => {
  test('matches only the exact prefix at the start', () => {
    expect(isCrewPrompt('[crew] review item 3')).toBe(true)
    expect(isCrewPrompt('[crew] line one\nline two')).toBe(true)
    expect(isCrewPrompt('review item 3')).toBe(false)
    expect(isCrewPrompt('please [crew] review')).toBe(false)
    expect(isCrewPrompt(' [crew] review')).toBe(false)
    expect(isCrewPrompt('[crew]review')).toBe(false)
    expect(isCrewPrompt('[Crew] review')).toBe(false)
  })
})

describe('gateQuestion', () => {
  test('quotes the re-write and offers a clear that re-writes nothing', () => {
    expect(gateQuestion({ idleMs: 72 * MINUTE, tokens: 380_000, rewriteUsd: 3.04 })).toBe(
      'The prompt cache has likely expired (idle 72m). Sending re-writes ~380k tokens (≈ $3.04); ' +
        'clearing hands off to a fresh session with the digest and re-writes nothing. What now?',
    )
  })
})

describe('handoffPrompt', () => {
  test('puts one continuation line above the typed text', () => {
    expect(handoffPrompt('fix the tests')).toBe("Continue from the previous session's handoff digest.\n\nfix the tests")
  })
})

describe('formatUsd', () => {
  test('shows cents, and a floor under one cent', () => {
    expect(formatUsd(3.04)).toBe('$3.04')
    expect(formatUsd(0.004)).toBe('<$0.01')
  })
})

describe('segmentFor', () => {
  const last: LastResponse = { at: 0, ctx: 380_000, model: OPUS }

  test('warm shows the time left', () => {
    expect(segmentFor(last, 380_000, 18 * MINUTE, 60 * MINUTE)).toEqual({ text: 'cache 42m', tone: 'normal' })
  })

  test('cold shows what the next send re-writes, as a warning', () => {
    expect(segmentFor(last, 380_000, 61 * MINUTE, 60 * MINUTE)).toEqual({ text: 'cache cold ≈ $3.04', tone: 'warn' })
  })

  test('prices the live context size, not the remembered one', () => {
    expect(segmentFor(last, 100_000, 61 * MINUTE, 60 * MINUTE)).toEqual({ text: 'cache cold ≈ $0.80', tone: 'warn' })
  })

  test('hides under 20k tokens of context, and without a live size or a previous response', () => {
    expect(segmentFor(last, 19_000, 0, 60 * MINUTE)).toBeNull()
    expect(segmentFor(last, undefined, 0, 60 * MINUTE)).toBeNull()
    expect(segmentFor(null, 380_000, 0, 60 * MINUTE)).toBeNull()
  })
})

describe('segmentFile', () => {
  test('writes text, tone and time as JSON, and nothing for no segment', () => {
    expect(JSON.parse(segmentFile({ text: 'cache 42m', tone: 'normal' }, 5))).toEqual({ text: 'cache 42m', tone: 'normal', at: 5 })
    expect(segmentFile(null, 5)).toBe('')
  })
})

describe('agents', () => {
  const ttl = 5 * MINUTE
  const now = 100 * MINUTE
  const track = (lastAt: number, ctx = 120_000, firstAt = lastAt): AgentTrack => ({ at: lastAt, firstAt, ctx, model: OPUS })
  const listed = (id: string, status: ListedAgent['status'], type = 'Explore'): ListedAgent => ({
    id,
    type,
    description: `task ${id}`,
    status,
  })

  test('alerts an idle or waiting agent past the TTL with a large context', () => {
    const agents = { a: track(now - 9 * MINUTE), b: track(now - 9 * MINUTE) }
    const { rows, more } = agentAlerts(agents, [listed('a', 'idle'), listed('b', 'waiting')], now, ttl, [])
    expect(rows.map(r => r.text)).toEqual([
      'Explore "task a" idle 9m · resuming re-writes 120k ≈ $0.60',
      'Explore "task b" idle 9m · resuming re-writes 120k ≈ $0.60',
    ])
    expect(more).toBe(0)
  })

  test('skips running, ended, small, fresh and untracked agents', () => {
    const agents = {
      run: track(now - 9 * MINUTE),
      done: track(now - 9 * MINUTE),
      small: track(now - 9 * MINUTE, 40_000),
      fresh: track(now - MINUTE),
    }
    const list = [listed('run', 'running'), listed('done', 'completed'), listed('small', 'idle'), listed('fresh', 'idle'), listed('ghost', 'idle')]
    expect(agentAlerts(agents, list, now, ttl, []).rows).toEqual([])
  })

  test('alerts an agent that has run over an hour', () => {
    const agents = { a: track(now - MINUTE, 10_000, now - 72 * MINUTE) }
    expect(agentAlerts(agents, [listed('a', 'running')], now, ttl, []).rows.map(r => r.text)).toEqual([
      'Explore "task a" has run 72m',
    ])
  })

  test('caps rows at three and counts the rest', () => {
    const ids = ['a', 'b', 'c', 'd', 'e']
    const agents = Object.fromEntries(ids.map(id => [id, track(now - 9 * MINUTE)]))
    const { rows, more } = agentAlerts(agents, ids.map(id => listed(id, 'idle')), now, ttl, [])
    expect(rows).toHaveLength(3)
    expect(more).toBe(2)
  })

  test('a dismissed alert stays hidden until the agent goes idle again', () => {
    const agents = { a: track(now - 9 * MINUTE) }
    const [row] = agentAlerts(agents, [listed('a', 'idle')], now, ttl, []).rows
    expect(agentAlerts(agents, [listed('a', 'idle')], now, ttl, [row?.key ?? '']).rows).toEqual([])
    const later = { a: track(now + MINUTE) }
    expect(agentAlerts(later, [listed('a', 'idle')], now + 10 * MINUTE, ttl, [row?.key ?? '']).rows).toHaveLength(1)
  })

  test('the segment counts live agents and warns on cold ones', () => {
    const agents = { a: track(now - 9 * MINUTE), b: track(now - MINUTE) }
    const list = [listed('a', 'idle'), listed('b', 'running'), listed('c', 'pending'), listed('d', 'completed')]
    expect(agentSegment(agents, list, now, ttl)).toEqual({ text: 'agents 3 · 1 cold', tone: 'warn' })
    expect(agentSegment({}, list, now, ttl)).toEqual({ text: 'agents 3', tone: 'normal' })
    expect(agentSegment(agents, [listed('d', 'completed')], now, ttl)).toBeNull()
  })

  test('segments join in order and warn when either warns', () => {
    expect(joinSegments({ text: 'cache 42m', tone: 'normal' }, { text: 'agents 1 · 1 cold', tone: 'warn' })).toEqual({
      text: 'cache 42m · agents 1 · 1 cold',
      tone: 'warn',
    })
    expect(joinSegments(null, { text: 'agents 2', tone: 'normal' })).toEqual({ text: 'agents 2', tone: 'normal' })
    expect(joinSegments(null, null)).toBeNull()
  })

  test('tracks outlive the agent list for a day, so a late resume is still classified', () => {
    const tracks = { recent: track(now - 23 * 60 * MINUTE), old: track(now - 25 * 60 * MINUTE) }
    expect(Object.keys(pruneTracks(tracks, now))).toEqual(['recent'])
  })

  test('a cold agent step toasts with the agent type', () => {
    const miss = { at: 0, gapMs: 9 * MINUTE, tokens: 120_000, usd: 0.96, model: OPUS, agentId: 'a' }
    expect(agentMissToast('Explore', miss)).toBe('Agent Explore went cold after 9m: re-wrote 120k tokens (≈ $0.96)')
  })
})
