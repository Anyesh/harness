import { describe, expect, test } from 'claude-code/testing'

import {
  asBounds,
  classifyStep,
  effectiveTtl,
  formatUsd,
  gateDecision,
  learnTtl,
  noBounds,
  observeStep,
  priceFor,
  statusText,
} from '../hooks/rules'
import type { LastResponse } from '../types'

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

  test('cold when almost nothing was read and most was written', () => {
    expect(classifyStep(100_000, usage(9_000, 95_000))).toBe('cold')
  })

  test('neither in between, or without a previous context', () => {
    expect(classifyStep(100_000, usage(20_000, 80_000))).toBeNull()
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
    expect(o.last).toEqual({ at: 5, ctx: 3_300, model: OPUS })
    expect(o.miss).toBeNull()
  })

  test('a cold step after a long gap is a miss priced at the write rate', () => {
    const o = observeStep({ ...base, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 380_000) })
    expect(o.bounds.coldMinMs).toBe(72 * MINUTE)
    expect(o.miss).toMatchObject({ gapMs: 72 * MINUTE, tokens: 380_000 })
    expect(cents(o.miss?.usd)).toBe(3.04)
  })

  test('a cold step soon after the last response teaches nothing', () => {
    const o = observeStep({ ...base, startedAt: 2 * MINUTE, now: 3 * MINUTE, usage: usage(0, 380_000) })
    expect(o.bounds).toEqual(noBounds)
    expect(o.miss).toBeNull()
  })

  test('a model switch teaches nothing', () => {
    const o = observeStep({ ...base, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 380_000, 0, 'claude-sonnet-5-5') })
    expect(o.bounds).toEqual(noBounds)
    expect(o.miss).toBeNull()
  })

  test('a small cold rewrite is learnt from but not reported', () => {
    const small = { at: 0, ctx: 30_000, model: OPUS }
    const o = observeStep({ ...base, prev: small, startedAt: 72 * MINUTE, now: 73 * MINUTE, usage: usage(0, 30_000) })
    expect(o.bounds.coldMinMs).toBe(72 * MINUTE)
    expect(o.miss).toBeNull()
  })
})

describe('gateDecision', () => {
  const last: LastResponse = { at: 0, ctx: 380_000, model: OPUS }

  test('stays quiet before the TTL or without a previous response', () => {
    expect(gateDecision(last, 59 * MINUTE, 60 * MINUTE, 1)).toBeNull()
    expect(gateDecision(null, 600 * MINUTE, 60 * MINUTE, 1)).toBeNull()
  })

  test('asks past the TTL when the re-write costs at least the threshold', () => {
    const gate = gateDecision(last, 72 * MINUTE, 60 * MINUTE, 1)
    expect(gate).toMatchObject({ idleMs: 72 * MINUTE, tokens: 380_000 })
    expect(cents(gate?.rewriteUsd)).toBe(3.04)
    expect(cents(gate?.compactUsd)).toBe(1.52)
  })

  test('stays quiet when the re-write is under the threshold', () => {
    const small = { ...last, ctx: 100_000 }
    expect(gateDecision(small, 72 * MINUTE, 60 * MINUTE, 1)).toBeNull()
    expect(gateDecision(small, 72 * MINUTE, 60 * MINUTE, 0)).not.toBeNull()
  })
})

describe('formatUsd', () => {
  test('shows cents, and a floor under one cent', () => {
    expect(formatUsd(3.04)).toBe('$3.04')
    expect(formatUsd(0.004)).toBe('<$0.01')
  })
})

describe('statusText', () => {
  const last: LastResponse = { at: 0, ctx: 380_000, model: OPUS }

  test('warm shows the time left and the context', () => {
    expect(statusText(last, 18 * MINUTE, 60 * MINUTE)).toBe('cache warm · 42m left · 380k ctx')
  })

  test('cold shows what the next send re-writes', () => {
    expect(statusText(last, 61 * MINUTE, 60 * MINUTE)).toBe('cache cold · next send re-writes 380k ≈ $3.04')
  })

  test('hides under 20k tokens of context', () => {
    expect(statusText({ ...last, ctx: 19_000 }, 0, 60 * MINUTE)).toBeUndefined()
    expect(statusText(null, 0, 60 * MINUTE)).toBeUndefined()
  })
})
