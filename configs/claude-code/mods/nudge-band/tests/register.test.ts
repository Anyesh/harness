import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, SessionMessage } from 'claude-code'

const HOUR = 3_600_000
const NOW = 100 * HOUR
const ROOT = '/work/repo'
const DEVLOG = '/vault/wiki/projects/repo/devlog.md'
const INDEX = '/vault/wiki/index.md'
const BAND = {
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 } as never,
} as const
const FOOTER = { component: 'SessionMode', props: { modes: ['plan mode'] } } as const
const HUMANIZE = '/home/user/.claude/.humanize-active'
const OWNIT = '/home/user/.claude/.ownit-active'

type World = {
  files: Record<string, { mtimeMs: number; text?: string }>
  untracked: string[]
  top: string | null
  messages: SessionMessage[]
  filled: string[]
  contexts: (readonly string[] | undefined)[]
  beneath?: string
  footer?: readonly string[]
}

function world(on: On, env: Record<string, string>, seed: Partial<World> = {}): World {
  const w: World = { files: {}, untracked: [], top: ROOT, messages: [], filled: [], contexts: [], ...seed }
  mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/user', ...env })
  on('process.run', (_$, e) => {
    const ok = (stdout: string, exitCode = 0) => ({
      value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    })
    if (e.argv[1] === 'rev-parse') return w.top ? ok(`${w.top}\n`) : ok('', 128)
    if (e.argv[1] === 'ls-files') return ok(w.untracked.map(path => `${path}\n`).join(''))
    return { deny: `unexpected command ${e.argv.join(' ')}` }
  })
  on('fs.exists', (_$, e) => ({ value: e.path in w.files }))
  on('fs.stat', (_$, e) => {
    const file = w.files[e.path]
    if (!file) return { deny: `ENOENT ${e.path}` }
    return { value: { kind: 'file' as const, size: 1, mtimeMs: file.mtimeMs, isLink: false } }
  })
  on('fs.read', (_$, e) => ({ value: w.files[e.path]?.text ?? '' }))
  on('session.cwd', () => ({ value: ROOT }))
  on('session.messages', () => ({ value: w.messages }))
  on('ui.render', ($, e) => {
    if (e.component === 'SessionMode') {
      w.footer = (e.props as { modes: readonly string[] }).modes
      return { type: 'engine' as const, ref: 0 }
    }
    if (!w.beneath) return { type: 'engine' as const, ref: 0 }
    const { Text } = $.ui.resolve(e as never)
    return h(Text, { key: 'beneath' }, w.beneath) as never
  })
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('prompt.submit', (_$, e) => {
    w.contexts.push(e.context)
    return { text: e.text }
  })
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('prompt.fill', (_$, e) => {
    w.filled.push(e.text)
    return { isFilled: true }
  })
  return w
}

async function prompts($: Engine, count: number) {
  for (let i = 0; i < count; i += 1) {
    await $.prompt.submit({ text: `prompt ${i}`, wait: false, origin: { kind: 'composer' } as never })
  }
}

describe('prompt.submit context', () => {
  test('adds the hygiene line once at turn 5 and nowhere else', async ($, on) => {
    const w = world(on, {}, { untracked: ['PLAN.md', 'src/app.ts'], files: { [`${ROOT}/.scope.md`]: { mtimeMs: NOW } } })
    await prompts($, 7)
    const lines = w.contexts.map(c => (c ?? []).join('\n'))
    expect(lines.slice(0, 4).every(line => line === '')).toBe(true)
    expect(lines[4]).toContain('HYGIENE')
    expect(lines[4]).toContain('PLAN.md')
    expect(lines[4]).not.toContain('src/app.ts')
    expect(lines[5]).toBe('')
    expect(lines[6]).toBe('')
  })

  test('adds the wiki line at turn 5 and again after three edits', async ($, on) => {
    const w = world(on, { WIKI_VAULT: '/vault' }, { files: { [`${ROOT}/.scope.md`]: { mtimeMs: NOW } } })
    await prompts($, 5)
    expect((w.contexts[4] ?? []).join('\n')).toContain(DEVLOG)
    w.messages = [
      { role: 'user', text: 'go', toolUses: [] },
      {
        role: 'assistant',
        text: '',
        toolUses: ['a', 'b', 'c'].map(id => ({ tool_use_id: id, tool: 'Edit', input: {} })),
      },
    ]
    await $.turn.complete({ turnId: 't5', answer: 'done', durationMs: 1, isAborted: false, reason: 'answer', text: 'done' } as never)
    await prompts($, 1)
    expect((w.contexts[5] ?? []).join('\n')).toContain('WIKI:')
  })

  test('has no scope or wiki line with HARNESS_UNATTENDED=1', async ($, on) => {
    const w = world(on, { WIKI_VAULT: '/vault', HARNESS_UNATTENDED: '1' })
    await prompts($, 12)
    const lines = w.contexts.map(c => (c ?? []).join('\n'))
    expect(lines.every(line => !line.includes('WIKI') && !line.includes('SCOPE'))).toBe(true)
  })

  test('keeps the scope and wiki lines when HARNESS_UNATTENDED is not 1', async ($, on) => {
    const w = world(on, { WIKI_VAULT: '/vault', HARNESS_UNATTENDED: '0' })
    await prompts($, 12)
    const lines = w.contexts.map(c => (c ?? []).join('\n'))
    expect(lines[4]).toContain('WIKI:')
    expect(lines[9]).toContain('SCOPE CHECK')
  })

  test('has no wiki line without a vault', async ($, on) => {
    const w = world(on, {}, { files: { [`${ROOT}/.scope.md`]: { mtimeMs: NOW } } })
    await prompts($, 6)
    expect(w.contexts.every(c => !(c ?? []).join('\n').includes('WIKI'))).toBe(true)
  })
})

describe('band', () => {
  test('draws attention segments on terminal and desktop and fills prompts', async ($, on) => {
    const w = world(on, { WIKI_VAULT: '/vault' }, { untracked: ['notes.md'], files: { [INDEX]: { mtimeMs: NOW + 1 } } })
    await prompts($, 1)
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'nudge-band', surface, ...BAND })
      expect(await ui.find({ type: 'Text', text: 'scope: missing' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'wiki: devlog not written' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'junk: 1 file' })).toBeDefined()
      await ui.press({ key: 'scope' })
      await ui.press({ key: 'wiki' })
      await ui.unmount()
    }
    expect(w.filled.slice(0, 2)).toEqual(['/scope', '/devlog'])
  })

  test('keeps a band drawn beneath it', async ($, on) => {
    world(on, {}, { untracked: ['notes.md'], beneath: 'another mod' })
    await prompts($, 1)
    const ui = await $.ui.mount({ plugin: 'nudge-band', surface: 'terminal', ...BAND })
    expect(await ui.find({ key: 'junk' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: 'another mod' })).toBeDefined()
  })

  test('passes when nothing needs attention, and hides on Hide', async ($, on) => {
    const w = world(on, {}, { files: { [`${ROOT}/.scope.md`]: { mtimeMs: NOW } } })
    await prompts($, 1)
    const quiet = await $.ui.mount({ plugin: 'nudge-band', surface: 'terminal', ...BAND })
    expect(await quiet.find({ key: 'hide' })).toBeUndefined()
    await quiet.unmount()

    w.untracked = ['x.tmp']
    await prompts($, 1)
    const ui = await $.ui.mount({ plugin: 'nudge-band', surface: 'terminal', ...BAND })
    expect(await ui.find({ key: 'junk' })).toBeDefined()
    await ui.press({ key: 'hide' })
    expect(await ui.find({ key: 'junk' })).toBeUndefined()
  })
})

describe('footer modes', () => {
  test('adds humanize and ownit after the engine modes, and leaves them out of the band', async ($, on) => {
    const w = world(on, {}, { untracked: ['notes.md'], files: { [HUMANIZE]: { mtimeMs: NOW, text: 'on' }, [OWNIT]: { mtimeMs: NOW, text: 'strict' } } })
    await prompts($, 1)
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'nudge-band', surface, ...FOOTER })
      expect(w.footer).toEqual(['plan mode', 'humanize on', 'ownit strict'])
      await ui.unmount()
    }
    const band = await $.ui.mount({ plugin: 'nudge-band', surface: 'terminal', ...BAND })
    expect(await band.find({ type: 'Text', text: /humanize/ })).toBeUndefined()
  })

  test('passes the footer unchanged with no mode active', async ($, on) => {
    const w = world(on, {})
    await prompts($, 1)
    await $.ui.mount({ plugin: 'nudge-band', surface: 'terminal', ...FOOTER })
    expect(w.footer).toEqual(['plan mode'])
  })
})
