import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { On, TurnUsage } from 'claude-code'

const MINUTE = 60_000
const NOW = 1_000 * MINUTE
const OPUS = 'claude-opus-5-5'
const SEND = 'Send anyway'
const COMPACT = 'Compact first'
const DRAFT = 'Keep as draft'

type World = {
  clock: MockClock
  usage: TurnUsage | null
  answer: string | null
  asked: string[]
  sent: string[]
  filled: string[]
  toasts: string[]
  statuses: (string | undefined)[]
  compactions: number
  stored: Record<string, unknown>
}

function usage(read: number, write: number): TurnUsage {
  return { input_tokens: 0, cache_read_input_tokens: read, cache_creation_input_tokens: write, output_tokens: 10, model: OPUS }
}

function world(on: On): World {
  const w: World = {
    clock: mock.clock(on, { now: NOW }),
    usage: null,
    answer: SEND,
    asked: [],
    sent: [],
    filled: [],
    toasts: [],
    statuses: [],
    compactions: 0,
    stored: {},
  }
  on('store.get', (_$, e) => ({ value: w.stored[e.key] }))
  on('store.set', (_$, e) => {
    w.stored[e.key] = JSON.parse(JSON.stringify(e.value))
    return { value: undefined }
  })
  on('turn.step', async function* (_$, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: w.usage }
  })
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('prompt.submit', (_$, e) => {
    w.sent.push(e.text)
    return { text: e.text }
  })
  on('prompt.fill', (_$, e) => {
    w.filled.push(e.text)
    return { isFilled: true }
  })
  on('tool.call', { tool: 'AskUserQuestion' }, (_$, e) => {
    const question = e.questions[0]?.question ?? ''
    w.asked.push(question)
    if (w.answer === null) return { deny: 'dismissed' }
    return { result: { questions: e.questions, answers: { [question]: w.answer } } } as never
  })
  on('session.compact', () => {
    w.compactions += 1
    return { messages: [{ role: 'user' as const, text: 'summary', toolUses: [] }] }
  })
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.status', (_$, e) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  return w
}

async function step($: Engine, w: World, u: TurnUsage, agentId?: string) {
  w.usage = u
  const stream = $.turn.step({ turnId: 't', index: 0, model: OPUS, messageCount: 1, ...(agentId ? { agentId } : {}) })
  for await (const _chunk of stream) {
    // The stub yields nothing; draining the stream lets its result settle.
  }
  await stream.result
}

async function complete($: Engine, agentId?: string) {
  const fields = { turnId: 't', answer: 'ok', durationMs: 1, isAborted: false, reason: 'answer', text: 'ok' }
  await $.turn.complete({ ...fields, ...(agentId ? { agentId } : {}) } as never)
}

function submit($: Engine, text = 'next thing', kind = 'composer', turnId?: string) {
  return $.prompt.submit({ text, wait: false, origin: { kind } as never, ...(turnId ? { turnId } : {}) })
}

async function warmed($: Engine, w: World, idleMinutes: number) {
  await step($, w, usage(0, 380_000))
  await complete($)
  await w.clock.advance(idleMinutes * MINUTE)
}

describe('gate', () => {
  test('does not ask while the cache is warm', async ($, on) => {
    const w = world(on)
    await warmed($, w, 30)
    await submit($)
    expect(w.asked).toEqual([])
    expect(w.sent).toEqual(['next thing'])
  })

  test('asks after the TTL, and Send anyway sends', async ($, on) => {
    const w = world(on)
    await warmed($, w, 72)
    await submit($)
    expect(w.asked).toHaveLength(1)
    expect(w.asked[0]).toContain('idle 72m')
    expect(w.asked[0]).toContain('~380k tokens (≈ $3.04)')
    expect(w.asked[0]).toContain('(≈ $1.52)')
    expect(w.sent).toEqual(['next thing'])
  })

  test('Compact first compacts, puts the prompt back, and does not ask again', async ($, on) => {
    const w = world(on)
    w.answer = COMPACT
    await warmed($, w, 72)
    const result = await submit($)
    expect(result.drop).toContain('Compacting first')
    await w.clock.settle()
    expect(w.compactions).toBe(1)
    expect(w.filled).toEqual(['next thing'])
    expect(w.sent).toEqual([])
    await submit($)
    expect(w.asked).toHaveLength(1)
    expect(w.sent).toEqual(['next thing'])
  })

  test('Keep as draft puts the prompt back without sending or compacting', async ($, on) => {
    const w = world(on)
    w.answer = DRAFT
    await warmed($, w, 72)
    const result = await submit($)
    expect(result.drop).toBeDefined()
    expect(w.filled).toEqual(['next thing'])
    expect(w.sent).toEqual([])
    expect(w.compactions).toBe(0)
  })

  test('a dismissed or unanswerable ask sends', async ($, on) => {
    const w = world(on)
    w.answer = null
    await warmed($, w, 72)
    await submit($)
    expect(w.asked).toHaveLength(1)
    expect(w.sent).toEqual(['next thing'])
  })

  test('only gates an idle composer prompt', async ($, on) => {
    const w = world(on)
    await warmed($, w, 72)
    await submit($, 'from sdk', 'sdk')
    await submit($, 'typed mid-turn', 'composer', 'turn-1')
    expect(w.asked).toEqual([])
    expect(w.sent).toEqual(['from sdk', 'typed mid-turn'])
  })

  test('respects the gateUsd option', { options: { gateUsd: 5 } }, async ($, on) => {
    const w = world(on)
    await warmed($, w, 72)
    await submit($)
    expect(w.asked).toEqual([])
  })

  test('ignores subagent steps', async ($, on) => {
    const w = world(on)
    await step($, w, usage(0, 380_000), 'agent-1')
    await complete($, 'agent-1')
    await w.clock.advance(72 * MINUTE)
    await submit($)
    expect(w.asked).toEqual([])
  })
})

describe('misses', () => {
  test('a cold step toasts and records the miss', async ($, on) => {
    const w = world(on)
    await warmed($, w, 72)
    w.answer = SEND
    await submit($)
    await step($, w, usage(0, 380_000))
    expect(w.toasts).toEqual(['Cache went cold after 72m: re-wrote 380k tokens (≈ $3.04 at API prices)'])
    expect(w.stored.misses).toHaveLength(1)
  })

  test('a learnt shorter TTL gates sooner', async ($, on) => {
    const w = world(on)
    await warmed($, w, 20)
    await step($, w, usage(0, 380_000))
    await complete($)
    await w.clock.advance(25 * MINUTE)
    await submit($)
    expect(w.asked).toHaveLength(1)
  })
})

describe('status line', () => {
  test('shows warm after a turn and cold once the TTL passes', async ($, on) => {
    const w = world(on)
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await warmed($, w, 18)
    expect(w.statuses).toContain('cache warm · 60m left · 380k ctx')
    await w.clock.advance(43 * MINUTE)
    expect(w.statuses.at(-1)).toBe('cache cold · next send re-writes 380k ≈ $3.04')
  })
})
