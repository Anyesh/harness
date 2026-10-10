import { describe, expect, test } from 'claude-code/testing'

import { blockDetail, blockSegment, blockToast, guardName, segmentFile } from '../hooks/rules'
import type { Block } from '../types'

describe('guardName', () => {
  test('reads the harness guard prefixes', () => {
    expect(guardName('[hook:cost-guard] BLOCKED: file over 2 MB')).toBe('cost-guard')
    expect(guardName('BLOCKED by pre-bash-guard: force push to main')).toBe('pre-bash-guard')
    expect(guardName('BLOCKED by pre-bash-interactive-alias: `rm` is aliased')).toBe('pre-bash-interactive-alias')
  })

  test('names a [hook:global] block by the script path when the reason carries one', () => {
    expect(guardName('[bash /home/user/.claude/hooks/pre-edit-code-quality.sh]: [hook:global] BLOCKED: em dash')).toBe(
      'pre-edit-code-quality',
    )
    expect(guardName('[python3 /x/hooks/pre-edit-comment-guard.py]: narrative comment')).toBe('pre-edit-comment-guard')
  })

  test('falls back to guard', () => {
    expect(guardName('[hook:global] BLOCKED: em dash')).toBe('guard')
    expect(guardName('denied')).toBe('guard')
  })
})

describe('blockDetail', () => {
  test('keeps the first line after the BLOCKED marker', () => {
    expect(blockDetail('[hook:cost-guard] BLOCKED: file over 2 MB\nUse a subagent.')).toBe('file over 2 MB')
    expect(blockDetail('BLOCKED by pre-bash-guard: force push to main')).toBe('force push to main')
  })

  test('cuts a long reason', () => {
    expect(blockDetail(`BLOCKED: ${'x'.repeat(200)}`)).toHaveLength(80)
  })
})

describe('blockSegment', () => {
  const block = (agentId?: string): Block => ({ at: 0, guard: 'cost-guard', tool: 'Read', detail: 'big', ...(agentId ? { agentId } : {}) })

  test('counts blocks and warns when a subagent was blocked', () => {
    expect(blockSegment([])).toBeNull()
    expect(blockSegment([block()])).toEqual({ text: '1 block', tone: 'normal' })
    expect(blockSegment([block(), block('a1')])).toEqual({ text: '2 blocks', tone: 'warn' })
  })
})

describe('blockToast', () => {
  test('names the guard, the agent type and the tool', () => {
    const block: Block = { at: 0, guard: 'cost-guard', tool: 'Read', detail: 'file over 2 MB', agentId: 'a1' }
    expect(blockToast(block, 'Explore')).toBe("cost-guard blocked Explore's Read: file over 2 MB")
  })
})

describe('segmentFile', () => {
  test('writes text, tone and time as JSON, and nothing for no segment', () => {
    expect(JSON.parse(segmentFile({ text: '2 blocks', tone: 'warn' }, 5))).toEqual({ text: '2 blocks', tone: 'warn', at: 5 })
    expect(segmentFile(null, 5)).toBe('')
  })
})
