import type { EngineInterface, Register } from 'claude-code'

import {
  classicRequest,
  digestBlock,
  forkPrompt,
  handoffMessage,
  nextHandoffPath,
  reasoningOutline,
  withDigest,
} from './rules'

type Digest = { path: string; text: string }

async function buildDigest($: EngineInterface): Promise<Digest> {
  const [home, id, cwd] = await Promise.all([$.env.get('HOME'), $.session.id(), $.session.cwd()])
  if (!home) throw new Error('HOME is not set')
  const run = await $.process.run(['bash', `${home}/.claude/scripts/handoff-digest.sh`, id], { cwd, timeoutMs: 30_000 })
  const path = run.stdout.trim()
  if (run.exitCode !== 0 || path === '') throw new Error(`handoff-digest.sh exited ${run.exitCode}: ${run.stderr.trim()}`)
  return { path, text: await $.fs.read(path) }
}

async function writeReasoning($: EngineInterface, instructions: string | undefined): Promise<string> {
  const reply = await $.model.fork({ prompt: forkPrompt(instructions) })
  if (!reply.isAnswered) throw new Error(`fork gave no reply: ${reply.reason}`)
  if (reply.text.trim() === '') throw new Error('fork reply was blank')
  return reply.text
}

async function save($: EngineInterface, digestPath: string, text: string): Promise<string> {
  const dir = digestPath.slice(0, digestPath.lastIndexOf('/'))
  const names = (await $.fs.list(dir)).map(entry => entry.name)
  const path = nextHandoffPath(digestPath, names)
  await $.fs.write(path, text)
  return path
}

export const register: Register = on => {
  on('session.compact', async ($, e, next) => {
    if (e.agentId) return next(e)
    if (e.trigger === 'precompute') return { skip: 'handoff answers at compaction time' }
    const classic = classicRequest(e.trigger, e.instructions)
    if (classic) return next({ ...e, instructions: classic.instructions })

    const [digest, reasoning] = await Promise.allSettled([buildDigest($), writeReasoning($, e.instructions)])

    if (digest.status === 'rejected') {
      $.ui.log(`handoff: digest failed (${String(digest.reason)}), core summary covers the reasoning outline`, { to: 'debug' })
      return next({ ...e, instructions: reasoningOutline(e.instructions) })
    }
    const block = digestBlock(digest.value.text)

    if (reasoning.status === 'rejected') {
      $.ui.log(`handoff: ${String(reasoning.reason)}, keeping core summary plus the digest`, { to: 'debug' })
      const core = await next(e)
      if (core.skip !== undefined) return core
      return { ...core, messages: withDigest(core.messages, block, digest.value.path) }
    }

    const text = handoffMessage({ reasoning: reasoning.value, block, digestPath: digest.value.path, trigger: e.trigger })
    try {
      $.ui.toast(`handoff: ${await save($, digest.value.path, text)}`)
    } catch (err) {
      $.ui.log(`handoff: could not save the handoff file (${String(err)})`, { to: 'debug' })
    }
    return { messages: [{ role: 'user', text, toolUses: [] }] }
  }).catch(($, e, next) => next(e))
}
