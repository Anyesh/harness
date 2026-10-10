import { describe, expect, test } from 'claude-code/testing'
import type { SessionContextBreakdown } from 'claude-code'

import { auditText, mcpServers, skillGroups, trimCandidates } from '../hooks/rules'
import { BREAKDOWN } from './fixture'

describe('mcpServers', () => {
  test('sums tools per server, loaded apart from deferred, largest first', () => {
    expect(mcpServers(BREAKDOWN.mcpTools)).toEqual([
      { name: 'playwright', loaded: 5_600, deferred: 400, tools: 3 },
      { name: 'web', loaded: 800, deferred: 0, tools: 1 },
    ])
  })
})

describe('skillGroups', () => {
  test('groups by plugin, else by source, largest first', () => {
    expect(skillGroups(BREAKDOWN.skills?.skillFrontmatter ?? [])).toEqual([
      { name: 'userSettings', tokens: 1_700, count: 2 },
      { name: 'plugin feature-dev', tokens: 1_400, count: 2 },
      { name: 'built-in', tokens: 200, count: 1 },
    ])
  })
})

describe('trimCandidates', () => {
  test('lists servers over 5k, skills over 1k and memory files over 3k, with their share of the window', () => {
    expect(trimCandidates(BREAKDOWN)).toEqual([
      { label: 'MCP server playwright', tokens: 5_600, share: 0.0056 },
      { label: 'memory /home/user/.claude/CLAUDE.md', tokens: 4_200, share: 0.0042 },
      { label: 'skill impeccable', tokens: 1_400, share: 0.0014 },
    ])
  })

  test('keeps the five largest', () => {
    const many = {
      ...BREAKDOWN,
      memoryFiles: Array.from({ length: 8 }, (_, i) => ({ path: `/m${i}`, type: 'User', tokens: 3_001 + i })),
    } as SessionContextBreakdown
    const picked = trimCandidates(many)
    expect(picked).toHaveLength(5)
    expect(picked[0]?.label).toBe('MCP server playwright')
  })
})

describe('auditText', () => {
  test('prints each section and the trim list', () => {
    const text = auditText(BREAKDOWN)
    expect(text).toContain('380k of 1.0M (38%)')
    expect(text).toContain('  playwright  5.6k loaded  400 deferred  3 tools')
    expect(text).toContain('  web  800 loaded  0 deferred  1 tool')
    expect(text).toContain('  plugin feature-dev  1.4k  2 skills')
    expect(text).toContain('  4.2k  /home/user/.claude/CLAUDE.md')
    expect(text).toContain('  700  reviewer (projectSettings)')
    expect(text).toContain('Slash commands: 34 of 40 listed, 1.5k')
    expect(text).toContain('  MCP server playwright  5.6k  0.6% of the window')
  })

  test('says so when nothing is worth trimming', () => {
    const lean = { ...BREAKDOWN, mcpTools: [], memoryFiles: [], skills: undefined } as unknown as SessionContextBreakdown
    expect(auditText(lean)).toContain('Nothing over the trim thresholds.')
  })
})
