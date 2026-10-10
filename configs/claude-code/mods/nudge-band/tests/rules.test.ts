import { describe, expect, test } from 'claude-code/testing'

import {
  countTurnEdits,
  decide,
  initialArmed,
  isJunk,
  isToolingDir,
  projectSlug,
  scopeStatus,
} from '../hooks/rules'
import type { Armed, Snapshot } from '../types'

const HOUR = 3_600_000

const base: Snapshot = {
  root: '/work/repo',
  isGit: true,
  slug: 'repo',
  scope: { kind: 'fresh' },
  wiki: null,
  junk: [],
  humanize: null,
  ownit: null,
}

const unwritten = {
  devlogPath: '/vault/wiki/projects/repo/devlog.md',
  indexPath: '/vault/wiki/index.md',
  devlogWritten: false,
  indexWritten: false,
  latestWriteMs: 0,
}

function run(turns: number, snapshot: Snapshot, armed: Armed, edits = 0) {
  return decide({ turns, edits, snapshot, armed })
}

describe('isJunk', () => {
  test('keeps protected docs at any depth', () => {
    for (const path of ['README.md', 'CLAUDE.md', 'docs/LICENSE', '.scope.md', 'AGENTS.md']) {
      expect(isJunk(path), path).toBe(false)
    }
  })

  test('flags scratch docs only at the repo root', () => {
    for (const path of ['PLAN.md', 'handover.md', 'notes.md', 'feature.plan.md', 'tmp.json', 'debug.txt']) {
      expect(isJunk(path), path).toBe(true)
    }
    expect(isJunk('docs/plan.md')).toBe(false)
    expect(isJunk('src/notes.md')).toBe(false)
  })

  test('flags temp suffixes and scratch directories at any depth', () => {
    for (const path of ['a/b/c.tmp', 'x.bak', 'src/y.orig', 'deep/z.log', 'nohup.out', 'screenshots/a.txt', 'web/screenshots/b.png', 'pkg/tmp/x', '.scratch/n']) {
      expect(isJunk(path), path).toBe(true)
    }
  })

  test('flags lowercase image extensions at the root only', () => {
    expect(isJunk('shot.png')).toBe(true)
    expect(isJunk('assets/shot.png')).toBe(false)
    expect(isJunk('SHOT.PNG')).toBe(false)
  })

  test('leaves ordinary source files alone', () => {
    for (const path of ['src/index.ts', 'install.sh', 'docs/guide.md']) {
      expect(isJunk(path), path).toBe(false)
    }
  })
})

describe('paths', () => {
  test('slug lowercases and collapses separators', () => {
    expect(projectSlug('/home/user/My_Cool  Repo')).toBe('my-cool-repo')
    expect(projectSlug('/home/user/harness')).toBe('harness')
  })

  test('tooling dirs are recognised', () => {
    expect(isToolingDir('/home/user/.claude', '/home/user')).toBe(true)
    expect(isToolingDir('/somewhere/.cursor', '/home/user')).toBe(true)
    expect(isToolingDir('/home/user/harness', '/home/user')).toBe(false)
  })

  test('scope status reads missing, fresh and stale', () => {
    expect(scopeStatus(null, 10 * HOUR)).toEqual({ kind: 'missing' })
    expect(scopeStatus(9 * HOUR, 10 * HOUR)).toEqual({ kind: 'fresh' })
    expect(scopeStatus(7 * HOUR, 10 * HOUR)).toEqual({ kind: 'stale', ageHours: 3 })
  })
})

describe('scope', () => {
  const missing: Snapshot = { ...base, scope: { kind: 'missing' } }

  test('fires once from turn 10, not before', () => {
    expect(run(9, missing, initialArmed).messages).toEqual([])
    const first = run(10, missing, initialArmed)
    expect(first.messages).toHaveLength(1)
    expect(first.messages[0]).toContain('SCOPE CHECK (turn 10)')
    expect(first.messages[0]).toContain('.scope.md is missing')
    expect(run(11, missing, first.armed).messages).toEqual([])
    expect(run(20, missing, first.armed).messages).toEqual([])
  })

  test('re-arms after the file becomes fresh, then fires when stale again', () => {
    const fired = run(10, missing, initialArmed).armed
    const fresh = run(11, base, fired).armed
    const stale: Snapshot = { ...base, scope: { kind: 'stale', ageHours: 3 } }
    const again = run(12, stale, fresh)
    expect(again.messages).toHaveLength(1)
    expect(again.messages[0]).toContain('.scope.md is 3h old')
  })

  test('says nothing without a project root', () => {
    expect(run(10, { ...missing, root: null }, initialArmed).messages).toEqual([])
  })
})

describe('wiki', () => {
  const pending: Snapshot = { ...base, wiki: unwritten }

  test('fires first at turn 5', () => {
    expect(run(4, pending, initialArmed).messages).toEqual([])
    const first = run(5, pending, initialArmed)
    expect(first.messages).toHaveLength(1)
    expect(first.messages[0]).toContain('WIKI:')
    expect(first.messages[0]).toContain(unwritten.devlogPath)
    expect(first.messages[0]).toContain(unwritten.indexPath)
  })

  test('fires again after 3 more edits', () => {
    const first = run(5, pending, initialArmed, 0).armed
    expect(run(6, pending, first, 2).messages).toEqual([])
    expect(run(7, pending, first, 3).messages).toHaveLength(1)
  })

  test('fires again after 10 more turns with no edits', () => {
    const first = run(5, pending, initialArmed).armed
    expect(run(14, pending, first).messages).toEqual([])
    expect(run(15, pending, first).messages).toHaveLength(1)
  })

  test('stays quiet once both pages are written', () => {
    const done: Snapshot = {
      ...base,
      wiki: { ...unwritten, devlogWritten: true, indexWritten: true, latestWriteMs: 5000 },
    }
    const first = run(5, pending, initialArmed).armed
    const seen = run(6, done, first, 1).armed
    expect(run(7, done, seen, 2).messages).toEqual([])
  })

  test('a write moves the anchor, and later work asks for an update', () => {
    const first = run(5, pending, initialArmed, 0).armed
    const written: Snapshot = {
      ...base,
      wiki: { ...unwritten, devlogWritten: true, indexWritten: true, latestWriteMs: 9000 },
    }
    const afterWrite = run(6, written, first, 4)
    expect(afterWrite.messages).toEqual([])
    expect(run(7, written, afterWrite.armed, 6).messages).toEqual([])
    const update = run(8, written, afterWrite.armed, 7)
    expect(update.messages).toHaveLength(1)
    expect(update.messages[0]).toContain('since the last wiki update')
  })

  test('is off without a vault', () => {
    expect(run(5, base, initialArmed).messages).toEqual([])
  })
})

describe('cleanup', () => {
  test('waits for turn 5, then reports only new files', () => {
    const dirty: Snapshot = { ...base, junk: ['PLAN.md', 'x.tmp'] }
    expect(run(4, dirty, initialArmed).messages).toEqual([])
    const first = run(5, dirty, initialArmed)
    expect(first.messages).toHaveLength(1)
    expect(first.messages[0]).toContain('HYGIENE')
    expect(first.messages[0]).toContain('PLAN.md, x.tmp')
    expect(run(6, dirty, first.armed).messages).toEqual([])
    const more = run(7, { ...base, junk: ['PLAN.md', 'x.tmp', 'debug.txt'] }, first.armed)
    expect(more.messages).toHaveLength(1)
    expect(more.messages[0]).toContain('debug.txt')
    expect(more.messages[0]).not.toContain('PLAN.md')
  })

  test('reports a deleted file again when it comes back', () => {
    const first = run(5, { ...base, junk: ['PLAN.md'] }, initialArmed).armed
    const cleared = run(6, base, first).armed
    expect(run(7, { ...base, junk: ['PLAN.md'] }, cleared).messages).toHaveLength(1)
  })

  test('caps the list at ten names', () => {
    const junk = Array.from({ length: 12 }, (_, i) => `f${i}.tmp`)
    const message = run(5, { ...base, junk }, initialArmed).messages[0]
    expect(message).toContain('f9.tmp (and 2 more)')
    expect(message).not.toContain('f10.tmp')
  })
})

describe('countTurnEdits', () => {
  test('counts edit tools after the prompt that started the turn', () => {
    const rows = [
      { role: 'user' as const, text: 'earlier', toolUses: [] },
      { role: 'assistant' as const, text: '', toolUses: [{ tool_use_id: 'a', tool: 'Write', input: {} }] },
      { role: 'user' as const, text: 'now', toolUses: [] },
      { role: 'assistant' as const, text: '', toolUses: [{ tool_use_id: 'b', tool: 'Edit', input: {} }, { tool_use_id: 'c', tool: 'Bash', input: {} }] },
      { role: 'user' as const, text: '', toolUses: [], toolResults: [{ tool_use_id: 'b' }] },
      { role: 'assistant' as const, text: '', toolUses: [{ tool_use_id: 'd', tool: 'mcp__verdant__edit', input: {} }] },
    ]
    expect(countTurnEdits(rows)).toBe(2)
  })
})
