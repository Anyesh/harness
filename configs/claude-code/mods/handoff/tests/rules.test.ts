import { describe, expect, test } from 'claude-code/testing'

import {
  SECTIONS,
  classicRequest,
  digestBlock,
  forkPrompt,
  handoffMessage,
  nextHandoffPath,
  reasoningOutline,
  withDigest,
} from '../hooks/rules'

const DIGEST = [
  '# Handoff digest',
  'session: s1',
  '',
  '## Files touched (1)',
  '- /x/a.py',
  '',
  '## Last turns (newest turns, up to 12000 chars)',
  '',
  '### USER',
  'do it',
  '',
  '## Prompt index',
  '1. do it',
  '',
].join('\n')

describe('classicRequest', () => {
  test('matches /compact classic on a manual compaction and keeps the rest as instructions', () => {
    expect(classicRequest('manual', 'classic')).toEqual({ instructions: undefined })
    expect(classicRequest('manual', '  classic keep the API notes')).toEqual({ instructions: 'keep the API notes' })
  })

  test('ignores words that only start with classic, other triggers and no instructions', () => {
    expect(classicRequest('manual', 'classical music')).toBeUndefined()
    expect(classicRequest('manual', 'keep classic')).toBeUndefined()
    expect(classicRequest('auto', 'classic')).toBeUndefined()
    expect(classicRequest('manual', undefined)).toBeUndefined()
  })
})

describe('forkPrompt', () => {
  test('asks for every reasoning section, no tools, and says the latest message wins', () => {
    const prompt = forkPrompt()
    for (const s of SECTIONS) expect(prompt).toContain(`## ${s.title}`)
    expect(prompt).toContain('Use no tools')
    expect(prompt).toContain('latest user message wins over an older plan')
    expect(prompt).toContain('already lists the files touched')
    expect(prompt).not.toContain('/compact')
  })

  test('carries the /compact instructions', () => {
    expect(forkPrompt('stress the migration')).toContain('The user asked this compaction to: stress the migration')
  })
})

describe('reasoningOutline', () => {
  test('names the sections and keeps the user instructions first', () => {
    const outline = reasoningOutline('stress the migration')
    expect(outline.startsWith('stress the migration')).toBe(true)
    for (const s of SECTIONS) expect(outline).toContain(s.title)
    expect(reasoningOutline()).toContain('GOAL')
  })
})

describe('digestBlock', () => {
  test('cuts the digest above the prompt index and counts its lines', () => {
    const block = digestBlock(DIGEST)
    expect(block.text).toContain('## Last turns')
    expect(block.text).not.toContain('## Prompt index')
    expect(block.text.endsWith('do it')).toBe(true)
    expect(block.lines).toBe(10)
  })

  test('keeps a digest with no index whole', () => {
    expect(digestBlock('# Handoff digest\nsession: s1\n').text).toBe('# Handoff digest\nsession: s1')
  })
})

describe('handoffMessage', () => {
  test('starts with the [handoff] header naming the digest, then the reasoning, then the facts', () => {
    const text = handoffMessage({
      reasoning: '## GOAL\nship it',
      block: digestBlock(DIGEST),
      digestPath: '/h/proj/s1.md',
      trigger: 'auto',
    })
    expect(text.startsWith('[handoff] ')).toBe(true)
    expect(text).toContain('replaced')
    expect(text).toContain('/h/proj/s1.md')
    expect(text).toContain('trigger: auto')
    expect(text.indexOf('## GOAL')).toBeLessThan(text.indexOf('# Handoff digest'))
    expect(text).toContain('## Files touched (1)')
    expect(text).not.toContain('## Prompt index')
  })
})

describe('withDigest', () => {
  test('keeps core messages as they are and adds the digest block after them', () => {
    const core = [{ role: 'user' as const, text: 'summary', toolUses: [], handle: 'h1' }]
    const out = withDigest(core, digestBlock(DIGEST), '/h/proj/s1.md')
    expect(out).toHaveLength(2)
    expect(out[0]).toBe(core[0])
    expect(out[1]?.role).toBe('user')
    expect(out[1]?.text.startsWith('[handoff] ')).toBe(true)
    expect(out[1]?.text).toContain('/h/proj/s1.md')
    expect(out[1]?.text).toContain('## Files touched (1)')
  })
})

describe('nextHandoffPath', () => {
  test('numbers handoffs past the highest one already saved for the session', () => {
    expect(nextHandoffPath('/h/proj/s1.md', [])).toBe('/h/proj/s1.handoff-1.md')
    expect(nextHandoffPath('/h/proj/s1.md', ['s1.md', 's1.handoff-1.md', 's1.handoff-3.md', 's2.handoff-9.md'])).toBe(
      '/h/proj/s1.handoff-4.md',
    )
  })
})
