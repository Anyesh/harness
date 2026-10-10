import type { Register } from 'claude-code'

import { auditText } from './rules'

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'context-audit',
      description: 'Context by MCP server, skill group, memory file, agent and command, with what to trim',
      immediate: true,
    })
    return next(e)
  })

  on('command.run', { command: 'context-audit' }, async $ => {
    const usage = await $.session.usage({ breakdown: 'summary' })
    const breakdown = usage.context.breakdown
    if (!breakdown) return { text: 'No context breakdown yet: send a prompt first.' }
    return { text: auditText(breakdown) }
  })
}
