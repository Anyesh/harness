import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer, TurnUsage } from 'claude-code'

import {
  MINUTE,
  MISSES_KEPT,
  asBounds,
  asMisses,
  effectiveTtl,
  gateDecision,
  gateQuestion,
  missToast,
  observeStep,
  segmentFile,
  segmentFor,
} from './rules'

const last = atom({ plugin: 'cache-guard', key: 'last' } as const, null)
const misses = atom({ plugin: 'cache-guard', key: 'misses' } as const, [])

const SEND = 'Send anyway'
const COMPACT = 'Compact first'
const DRAFT = 'Keep as draft'
const SEGMENT_EVERY_MS = 30_000

type Config = { defaultTtlMs: number; gateUsd: number }

async function ttlMs($: EngineInterface, config: Config): Promise<number> {
  return effectiveTtl(asBounds(await $.store.get('ttl')), config.defaultTtlMs)
}

async function segmentPath($: EngineInterface, sessionId: string): Promise<string> {
  const state = (await $.env.get('XDG_STATE_HOME')) || `${await $.env.get('HOME')}/.local/state`
  return `${state}/harness/status/${sessionId}/cache-guard.json`
}

async function writeSegment($: EngineInterface, config: Config): Promise<void> {
  const segment = segmentFor(await read($, last), await $.clock.now(), await ttlMs($, config))
  await $.fs.write(await segmentPath($, await $.session.id()), segmentFile(segment, await $.clock.now()))
}

async function showSegment($: EngineInterface, config: Config): Promise<void> {
  try {
    await writeSegment($, config)
  } catch (err) {
    $.ui.log(`cache-guard: could not write the status segment: ${String(err)}`, { to: 'debug' })
  }
}

// The session folder is shared with other mods, so rmdir is expected to fail while theirs remain.
async function removeSegment($: EngineInterface, sessionId: string): Promise<void> {
  const path = await segmentPath($, sessionId)
  try {
    await $.process.run(['rm', '-f', path])
    await $.process.run(['rmdir', path.slice(0, path.lastIndexOf('/'))])
  } catch (err) {
    $.ui.log(`cache-guard: could not remove ${path} (${String(err)}), emptying it`, { to: 'debug' })
    await $.fs.write(path, '')
  }
}

async function forget($: EngineInterface, config: Config): Promise<void> {
  await update($, last, () => null)
  await showSegment($, config)
}

async function observe($: EngineInterface, config: Config, startedAt: number, usage: TurnUsage): Promise<void> {
  const seen = observeStep({
    prev: await read($, last),
    startedAt,
    now: await $.clock.now(),
    usage,
    bounds: asBounds(await $.store.get('ttl')),
    defaultTtlMs: config.defaultTtlMs,
  })
  await update($, last, () => seen.last)
  await $.store.set('ttl', seen.bounds)
  const miss = seen.miss
  if (!miss) return
  const kept = await update($, misses, list => [...list, miss].slice(-MISSES_KEPT))
  await $.store.set('misses', kept)
  $.ui.toast(missToast(miss))
}

async function compactThenRestore($: EngineInterface, config: Config, text: string): Promise<void> {
  try {
    const compacted = await $.session.compact()
    if (compacted.messages) await forget($, config)
    else $.ui.toast(`Compaction skipped: ${compacted.skip}`)
  } catch (err) {
    $.ui.toast(`Compaction failed: ${String(err)}`)
  }
  await $.prompt.fill({ text })
}

export const register: Register = (on, options) => {
  const config: Config = {
    defaultTtlMs: Number(options.ttlMinutes ?? 60) * MINUTE,
    gateUsd: Number(options.gateUsd ?? 1),
  }
  let ticker: Timer | undefined

  on('session.start', async ($, e, next) => {
    const stored = asMisses(await $.store.get('misses'))
    await update($, misses, () => stored)
    await showSegment($, config)
    ticker?.cancel()
    ticker = $.clock.every(SEGMENT_EVERY_MS, () => void showSegment($, config))
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    ticker?.cancel()
    ticker = undefined
    if (e.reason === 'clear') await update($, last, () => null)
    await removeSegment($, e.sessionId)
    return next(e)
  })

  // Per-step usage, because turn.complete sums every request of the turn and a
  // cold first request would hide behind the warm reads of the steps after it.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined) return yield* next(e)
    const startedAt = await $.clock.now()
    const response = yield* next(e)
    if (response.usage) {
      try {
        await observe($, config, startedAt, response.usage)
      } catch (err) {
        $.ui.log(`cache-guard: could not record step usage: ${String(err)}`, { to: 'debug' })
      }
    }
    return response
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) await showSegment($, config)
    return next(e)
  })

  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined && e.trigger !== 'precompute' && result.messages) await forget($, config)
    return result
  }).catch(($, e, next) => next(e))

  // Fails open because this is a cost warning: a broken guard must never eat a prompt.
  on('prompt.submit', async ($, e, next) => {
    // Attachments cannot be put back in the prompt box, so a prompt carrying them is never held.
    if (e.origin.kind !== 'composer' || e.turnId !== undefined || e.attachments) return next(e)
    const gate = gateDecision(await read($, last), await $.clock.now(), await ttlMs($, config), config.gateUsd)
    if (!gate) return next(e)

    const choice = await $.ui
      .ask(gateQuestion(gate), { header: 'Cold cache', options: [SEND, COMPACT, DRAFT] })
      .catch((err: unknown) => {
        $.ui.log(`cache-guard: cold cache question unanswered (${String(err)}), sending`, { to: 'debug' })
        return SEND
      })

    if (choice === COMPACT) {
      // The host refuses a compaction under the prompt this hook is holding, so it runs once the prompt is dropped.
      $.clock.after(0, () => void compactThenRestore($, config, e.text))
      return { drop: 'Compacting first; your prompt will be back in the box.' }
    }
    if (choice === DRAFT) {
      await $.prompt.fill({ text: e.text })
      return { drop: 'Kept as a draft; the prompt cache is still cold.' }
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
