import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { AgentInfo, On } from 'claude-code'

const NOW = 1_000_000
const SEGMENT = '/state/harness/status/sess-1/guard-watch.json'
const COST = '[hook:cost-guard] BLOCKED: file over 2 MB\nDelegate the read to a subagent.'

type World = {
  clock: MockClock
  verdict: { decision: 'allow' | 'ask' | 'deny'; reason?: string; hook?: string }
  files: Record<string, string>
  toasts: string[]
  agents: AgentInfo[]
}

function world(on: On): World {
  const w: World = { clock: mock.clock(on, { now: NOW }), verdict: { decision: 'allow' }, files: {}, toasts: [], agents: [] }
  mock.env(on, { XDG_STATE_HOME: '/state', HOME: '/home/user' })
  on('session.id', () => ({ value: 'sess-1' }))
  on('agent.list', () => ({ value: w.agents }))
  on('fs.write', (_$, e) => {
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('process.run', (_$, e) => {
    if (e.argv[0] === 'rm') delete w.files[e.argv[2] ?? '']
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('tool.check', () => w.verdict)
  return w
}

function check($: Engine, tool: string, agentId?: string) {
  return $.tool.check({ tool, input: {}, tool_use_id: 'tu', ...(agentId ? { agentId } : {}) } as never)
}

function segment(w: World) {
  const text = w.files[SEGMENT]
  return text ? JSON.parse(text) : text
}

describe('tool.check observer', () => {
  test('returns the verdict unchanged and records a PreToolUse deny', async ($, on) => {
    const w = world(on)
    w.verdict = { decision: 'deny', hook: 'PreToolUse', reason: COST }
    expect(await check($, 'Read')).toEqual(w.verdict)
    expect(segment(w)).toEqual({ text: '1 block', tone: 'normal', at: NOW })
    expect(w.toasts).toEqual([])
  })

  test('ignores allows, asks and denies that no settings hook made', async ($, on) => {
    const w = world(on)
    for (const verdict of [
      { decision: 'allow' as const },
      { decision: 'ask' as const, hook: 'PreToolUse' },
      { decision: 'deny' as const, reason: 'Bash(git push:*)' },
    ]) {
      w.verdict = verdict
      expect(await check($, 'Bash')).toEqual(verdict)
    }
    expect(w.files[SEGMENT]).toBeUndefined()
  })

  test('toasts a subagent block with the agent type and warns in the segment', async ($, on) => {
    const w = world(on)
    w.agents = [{ id: 'a1', type: 'Explore', description: 'Find logs', status: 'running' }]
    w.verdict = { decision: 'deny', hook: 'PreToolUse', reason: COST }
    await check($, 'Bash')
    await check($, 'Read', 'a1')
    expect(w.toasts).toEqual(["cost-guard blocked Explore's Read: file over 2 MB"])
    expect(segment(w)).toMatchObject({ text: '2 blocks', tone: 'warn' })
  })
})

describe('session', () => {
  test('refreshes the segment on a ticker, removes it at the end, and clear forgets the blocks', async ($, on) => {
    const w = world(on)
    on('session.start', (_$, e) => ({ cwd: e.cwd }))
    on('session.end', (_$, e) => ({ sessionId: e.sessionId }) as never)
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    w.verdict = { decision: 'deny', hook: 'PreToolUse', reason: COST }
    await check($, 'Read')
    await w.clock.advance(30_000)
    expect(segment(w)).toMatchObject({ text: '1 block', at: NOW + 30_000 })
    await $.session.end({ reason: 'clear', sessionId: 'sess-1' } as never)
    expect(w.files[SEGMENT]).toBeUndefined()
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    expect(w.files[SEGMENT]).toBe('')
  })
})
