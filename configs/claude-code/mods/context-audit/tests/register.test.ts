import { describe, expect, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, SessionUsage } from 'claude-code'

import { BREAKDOWN } from './fixture'

function world(on: On, usage: SessionUsage) {
  const registered: string[] = []
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.register', (_$, e) => {
    registered.push(e.name)
    return { value: { command: e.name } }
  })
  on('session.usage', () => ({ value: usage }))
  return registered
}

function run($: Engine) {
  return $.command.run({ command: 'context-audit', args: '', origin: { kind: 'composer' }, presentation: 'transcript' } as never)
}

describe('/context-audit', () => {
  test('registers the command and prints the audit of the summary breakdown', async ($, on) => {
    const registered = world(on, { startedAt: 0, rateLimits: [], context: { window: 1_000_000, breakdown: BREAKDOWN } })
    await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
    expect(registered).toEqual(['context-audit'])
    const { text } = await run($)
    expect(text).toContain('Context audit: 380k of 1.0M (38%)')
    expect(text).toContain('MCP server playwright')
  })

  test('says so before the first response, when there is no breakdown', async ($, on) => {
    world(on, { startedAt: 0, rateLimits: [], context: { window: 1_000_000 } })
    const { text } = await run($)
    expect(text).toBe('No context breakdown yet: send a prompt first.')
  })
})
