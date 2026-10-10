import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { AgentInfo, On, TurnUsage } from 'claude-code'

const MINUTE = 60_000
const NOW = 1_000 * MINUTE
const OPUS = 'claude-opus-5-5'
const SEND = 'Send anyway'
const COMPACT = 'Compact first'
const DRAFT = 'Keep as draft'
const SEGMENT = '/state/harness/status/sess-1/cache-guard.json'

type World = {
  clock: MockClock
  usage: TurnUsage | null
  answer: string | null
  asked: string[]
  sent: string[]
  filled: string[]
  toasts: string[]
  statuses: (string | undefined)[]
  files: Record<string, string>
  agents: AgentInfo[]
  commands: string[][]
  compactions: number
  stored: Record<string, unknown>
}

function usage(read: number, write: number): TurnUsage {
  return { input_tokens: 0, cache_read_input_tokens: read, cache_creation_input_tokens: write, output_tokens: 10, model: OPUS }
}

function world(on: On, env: Record<string, string> = { XDG_STATE_HOME: '/state', HOME: '/home/user' }): World {
  const w: World = {
    clock: mock.clock(on, { now: NOW }),
    usage: null,
    answer: SEND,
    asked: [],
    sent: [],
    filled: [],
    toasts: [],
    statuses: [],
    files: {},
    agents: [],
    commands: [],
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
  on('session.id', () => ({ value: 'sess-1' }))
  on('agent.list', () => ({ value: w.agents }))
  on('env.get', (_$, e) => ({ value: env[e.name] }))
  on('fs.write', (_$, e) => {
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    w.commands.push([...e.argv])
    if (e.argv[0] === 'rm') delete w.files[e.argv[2] ?? '']
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
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

  test('subagent steps do not gate the main thread', async ($, on) => {
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

function segment(w: World) {
  const text = w.files[SEGMENT]
  return text ? JSON.parse(text) : text
}

describe('status segment', () => {
  test('writes warm after a turn and cold once the TTL passes, never a ui.status', async ($, on) => {
    const w = world(on)
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    await warmed($, w, 18)
    expect(segment(w)).toEqual({ text: 'cache 42m', tone: 'normal', at: NOW + 18 * MINUTE })
    await w.clock.advance(43 * MINUTE)
    expect(segment(w)).toMatchObject({ text: 'cache cold ≈ $3.04', tone: 'warn' })
    expect(w.statuses).toEqual([])
  })

  test('falls back to HOME when XDG_STATE_HOME is unset', async ($, on) => {
    const w = world(on, { HOME: '/home/user' })
    await warmed($, w, 1)
    expect(Object.keys(w.files)).toEqual(['/home/user/.local/state/harness/status/sess-1/cache-guard.json'])
  })

  test('removes the segment file when the session ends', async ($, on) => {
    const w = world(on)
    on('session.end', (_$, e) => ({ sessionId: e.sessionId }) as never)
    await warmed($, w, 1)
    await $.session.end({ reason: 'exit', sessionId: 'sess-1' } as never)
    expect(w.files[SEGMENT]).toBeUndefined()
    expect(w.commands).toEqual([
      ['rm', '-f', SEGMENT],
      ['rmdir', '/state/harness/status/sess-1'],
    ])
  })
})

const BAND = {
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 } as never,
} as const

function agent(id: string, status: AgentInfo['status']): AgentInfo {
  return { id, type: 'Explore', description: 'Research agent APIs', status }
}

async function start($: Engine, on: On) {
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
}

describe('agents', () => {
  test('a subagent step shows in the segment while the agent is listed', async ($, on) => {
    const w = world(on)
    await start($, on)
    w.agents = [agent('a1', 'running')]
    await step($, w, usage(0, 120_000), 'a1')
    await complete($, 'a1')
    expect(segment(w)).toMatchObject({ text: 'agents 1', tone: 'normal' })
    w.agents = [agent('a1', 'idle')]
    await w.clock.advance(6 * MINUTE)
    expect(segment(w)).toMatchObject({ text: 'agents 1 · 1 cold', tone: 'warn' })
  })

  test('an agent leaves the segment once unlisted, and a later cold resume still toasts', async ($, on) => {
    const w = world(on)
    await start($, on)
    w.agents = [agent('a1', 'running')]
    await step($, w, usage(0, 120_000), 'a1')
    w.agents = []
    await w.clock.advance(30_000)
    expect(segment(w)).toBe('')
    await w.clock.advance(9 * MINUTE)
    w.agents = [agent('a1', 'running')]
    await step($, w, usage(0, 120_000), 'a1')
    expect(w.toasts).toEqual(['Agent Explore went cold after 9m: re-wrote 120k tokens (≈ $0.60)'])
  })

  test('a cold agent step toasts and records the miss', async ($, on) => {
    const w = world(on)
    w.agents = [agent('a1', 'idle')]
    await step($, w, usage(0, 120_000), 'a1')
    await w.clock.advance(9 * MINUTE)
    await step($, w, usage(0, 120_000), 'a1')
    expect(w.toasts).toEqual(['Agent Explore went cold after 9m: re-wrote 120k tokens (≈ $0.60)'])
    expect(w.stored.misses).toMatchObject([{ agentId: 'a1', tokens: 120_000 }])
  })

  test('the band alerts an idle agent past its TTL, passes next(e), and dismisses', async ($, on) => {
    const w = world(on)
    on('ui.render', ($, e) => {
      const { Text } = $.ui.resolve(e as never)
      return h(Text, { key: 'beneath' }, 'another mod') as never
    })
    await start($, on)
    w.agents = [agent('a1', 'idle')]
    await step($, w, usage(0, 120_000), 'a1')
    await w.clock.advance(9 * MINUTE)
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'cache-guard', surface, ...BAND })
      const row = 'Explore "Research agent APIs" idle 9m · resuming re-writes 120k ≈ $0.60'
      expect(await ui.find({ type: 'Text', text: row })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'another mod' })).toBeDefined()
      await ui.unmount()
    }
    const ui = await $.ui.mount({ plugin: 'cache-guard', surface: 'terminal', ...BAND })
    await ui.press({ key: `dismiss-a1@${NOW}` })
    expect(await ui.find({ type: 'Text', text: /idle 9m/ })).toBeUndefined()
  })

  test('the band stays out of the way of a survey', async ($, on) => {
    const w = world(on)
    on('ui.render', () => ({ type: 'engine' as const, ref: 0 }))
    await start($, on)
    w.agents = [agent('a1', 'idle')]
    await step($, w, usage(0, 120_000), 'a1')
    await w.clock.advance(9 * MINUTE)
    const ui = await $.ui.mount({ plugin: 'cache-guard', surface: 'terminal', ...BAND, props: { hasSurvey: true, isWorking: false, maxRows: 10, bodyColumns: 120 } as never })
    expect(await ui.find({ type: 'Text', text: /idle 9m/ })).toBeUndefined()
  })
})
