import { describe, expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { ModelForkResult, On, SessionCompactInput, SessionMessage } from 'claude-code'

const HOME = '/home/user'
const DIGEST_PATH = `${HOME}/.claude/handoffs/proj/sess-1.md`
const DIGEST = '# Handoff digest\nsession: sess-1\n\n## Files touched (1)\n- /x/a.py\n\n## Prompt index\n1. do it\n'
const CORE: SessionMessage = { role: 'user', text: 'core summary', toolUses: [], handle: 'h-core' }
const USAGE = { input_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0, output_tokens: 1 }

type World = {
  fork: ModelForkResult
  forkPrompts: string[]
  digestExit: number
  commands: { argv: string[]; cwd?: string }[]
  files: Record<string, string>
  core: SessionCompactInput[]
  toasts: string[]
}

function world(on: On): World {
  const w: World = {
    fork: { isAnswered: true, text: '## GOAL\nship it', usage: USAGE },
    forkPrompts: [],
    digestExit: 0,
    commands: [],
    files: { [DIGEST_PATH]: DIGEST },
    core: [],
    toasts: [],
  }
  on('session.id', () => ({ value: 'sess-1' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? HOME : undefined }))
  on('process.run', (_$, e) => {
    w.commands.push({ argv: [...e.argv], cwd: e.init?.cwd })
    const ok = w.digestExit === 0
    return { value: { exitCode: w.digestExit, stdout: ok ? `${DIGEST_PATH}\n` : '', stderr: ok ? '' : 'no transcript', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('fs.read', (_$, e) => {
    const text = w.files[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.list', () => ({ value: Object.keys(w.files).map(p => ({ name: p.slice(p.lastIndexOf('/') + 1), kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) }))
  on('model.fork', (_$, e) => {
    w.forkPrompts.push(e.prompt)
    return { value: w.fork }
  })
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.log', () => ({ value: undefined }))
  on('session.compact', (_$, e) => {
    w.core.push(e)
    return { messages: [CORE] }
  })
  return w
}

function compact($: Engine, e: Partial<SessionCompactInput> & Pick<SessionCompactInput, 'trigger'>) {
  return $.session.compact({ messages: [{ role: 'user', text: 'do it', toolUses: [], handle: 'h-1' }], ...e } as never)
}

describe('session.compact', () => {
  for (const trigger of ['auto', 'manual', 'plugin'] as const) {
    test(`${trigger}: answers with one handoff message and saves it beside the digest`, async ($, on) => {
      const w = world(on)
      const result = await compact($, { trigger })
      expect(w.core).toEqual([])
      expect(result.messages).toHaveLength(1)
      const text = result.messages?.[0]?.text ?? ''
      expect(text.startsWith('[handoff] ')).toBe(true)
      expect(text).toContain('## GOAL\nship it')
      expect(text).toContain('## Files touched (1)')
      expect(text).not.toContain('## Prompt index')
      expect(w.commands).toEqual([{ argv: ['bash', `${HOME}/.claude/scripts/handoff-digest.sh`, 'sess-1'], cwd: '/work' }])
      expect(w.files[`${HOME}/.claude/handoffs/proj/sess-1.handoff-1.md`]).toBe(text)
      expect(w.toasts[0]).toContain('sess-1.handoff-1.md')
    })
  }

  test('a second compaction saves the next numbered handoff', async ($, on) => {
    const w = world(on)
    await compact($, { trigger: 'auto' })
    await compact($, { trigger: 'auto' })
    expect(Object.keys(w.files).filter(p => p.includes('.handoff-'))).toEqual([
      `${HOME}/.claude/handoffs/proj/sess-1.handoff-1.md`,
      `${HOME}/.claude/handoffs/proj/sess-1.handoff-2.md`,
    ])
  })

  test('passes the /compact text to the fork', async ($, on) => {
    const w = world(on)
    await compact($, { trigger: 'manual', instructions: 'stress the migration' })
    expect(w.forkPrompts[0]).toContain('stress the migration')
  })

  test('a subagent compaction goes to core untouched', async ($, on) => {
    const w = world(on)
    const result = await compact($, { trigger: 'auto', agentId: 'agent-1' })
    expect(result.messages).toEqual([CORE])
    expect(w.commands).toEqual([])
    expect(w.forkPrompts).toEqual([])
  })

  test('precompute is skipped, since handoff answers at compaction time', async ($, on) => {
    const w = world(on)
    const result = await compact($, { trigger: 'precompute' })
    expect(result.skip).toBeDefined()
    expect(w.core).toEqual([])
  })

  test('/compact classic goes to core with the remaining text', async ($, on) => {
    const w = world(on)
    const result = await compact($, { trigger: 'manual', instructions: 'classic keep the API notes' })
    expect(result.messages).toEqual([CORE])
    expect(w.core[0]?.instructions).toBe('keep the API notes')
    expect(w.forkPrompts).toEqual([])
  })

  test('a failed fork keeps core summary and adds the digest block', async ($, on) => {
    const w = world(on)
    w.fork = { isAnswered: false, reason: 'empty-reply', usage: USAGE }
    const result = await compact($, { trigger: 'auto' })
    expect(w.core).toHaveLength(1)
    expect(result.messages).toHaveLength(2)
    expect(result.messages?.[0]).toMatchObject({ text: 'core summary' })
    expect(result.messages?.[1]?.text).toContain('## Files touched (1)')
  })

  test('a blank fork reply counts as failed', async ($, on) => {
    const w = world(on)
    w.fork = { isAnswered: true, text: '  \n', usage: USAGE }
    const result = await compact($, { trigger: 'auto' })
    expect(w.core).toHaveLength(1)
    expect(result.messages).toHaveLength(2)
  })

  test('a failed digest sends core the reasoning outline as instructions', async ($, on) => {
    const w = world(on)
    w.digestExit = 1
    const result = await compact($, { trigger: 'manual', instructions: 'stress the migration' })
    expect(result.messages).toEqual([CORE])
    expect(w.core[0]?.instructions).toContain('stress the migration')
    expect(w.core[0]?.instructions).toContain('DECISIONS AND REASONS')
  })
})
