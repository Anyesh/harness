import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import { blockDetail, blockSegment, blockToast, guardName, segmentFile } from './rules'

const blocks = atom({ plugin: 'guard-watch', key: 'blocks' } as const, [])

const SEGMENT_EVERY_MS = 30_000

async function segmentPath($: EngineInterface, sessionId: string): Promise<string> {
  const state = (await $.env.get('XDG_STATE_HOME')) || `${await $.env.get('HOME')}/.local/state`
  return `${state}/harness/status/${sessionId}/guard-watch.json`
}

async function showSegment($: EngineInterface): Promise<void> {
  try {
    const segment = blockSegment(await read($, blocks))
    await $.fs.write(await segmentPath($, await $.session.id()), segmentFile(segment, await $.clock.now()))
  } catch (err) {
    $.ui.log(`guard-watch: could not write the status segment: ${String(err)}`, { to: 'debug' })
  }
}

// The session folder is shared with other mods, so rmdir is expected to fail while theirs remain.
async function removeSegment($: EngineInterface, sessionId: string): Promise<void> {
  const path = await segmentPath($, sessionId)
  try {
    await $.process.run(['rm', '-f', path])
    await $.process.run(['rmdir', path.slice(0, path.lastIndexOf('/'))])
  } catch (err) {
    $.ui.log(`guard-watch: could not remove ${path} (${String(err)}), emptying it`, { to: 'debug' })
    await $.fs.write(path, '')
  }
}

type Denied = { tool: string; agentId?: string; reason: string }

async function record($: EngineInterface, denied: Denied): Promise<void> {
  const block = {
    at: await $.clock.now(),
    guard: guardName(denied.reason),
    tool: denied.tool,
    detail: blockDetail(denied.reason),
    ...(denied.agentId !== undefined ? { agentId: denied.agentId } : {}),
  }
  await update($, blocks, list => [...list, block])
  await showSegment($)
  // A main-thread block already shows as a tool error in the transcript; a subagent's never reaches it.
  if (denied.agentId === undefined) return
  const type = (await $.agent.list()).find(a => a.id === denied.agentId)?.type ?? 'a subagent'
  $.ui.toast(blockToast(block, type))
}

export const register: Register = on => {
  let ticker: Timer | undefined

  on('session.start', async ($, e, next) => {
    await showSegment($)
    ticker?.cancel()
    ticker = $.clock.every(SEGMENT_EVERY_MS, () => void showSegment($))
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    ticker?.cancel()
    ticker = undefined
    if (e.reason === 'clear') await update($, blocks, () => [])
    await removeSegment($, e.sessionId)
    return next(e)
  })

  // An observer, never a decider: it reads the verdict the settings guards reached and returns it unchanged.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict.decision === 'deny' && verdict.hook === 'PreToolUse') {
      try {
        await record($, { tool: e.tool, agentId: e.agentId, reason: verdict.reason ?? '' })
      } catch (err) {
        $.ui.log(`guard-watch: could not record a block: ${String(err)}`, { to: 'debug' })
      }
    }
    return verdict
  }).catch(($, e, next) => next(e))
}
