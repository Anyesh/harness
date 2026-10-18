import { atom, read, update } from 'claude-code'
import type { AgentInfo, EngineInterface, Register, Timer, TurnUsage } from 'claude-code'

import {
  agentAlerts,
  agentMissToast,
  agentSegment,
  MINUTE,
  MISSES_KEPT,
  asBounds,
  asMisses,
  effectiveTtl,
  gateDecision,
  gateQuestion,
  handoffPrompt,
  joinSegments,
  missToast,
  observeStep,
  pruneTracks,
  segmentFile,
  segmentFor,
} from './rules'

const last = atom({ plugin: 'cache-guard', key: 'last' } as const, null)
const misses = atom({ plugin: 'cache-guard', key: 'misses' } as const, [])
const agents = atom({ plugin: 'cache-guard', key: 'agents' } as const, {})
const listed = atom({ plugin: 'cache-guard', key: 'listed' } as const, [])
const dismissed = atom({ plugin: 'cache-guard', key: 'dismissed' } as const, [])

const SEND = 'Send anyway'
const CLEAR = 'Clear and hand off'
const DRAFT = 'Keep as draft'
const SEGMENT_EVERY_MS = 30_000

type Config = { defaultTtlMs: number; agentTtlMs: number; gateUsd: number }

async function ttlMs($: EngineInterface, config: Config): Promise<number> {
  return effectiveTtl(asBounds(await $.store.get('ttl')), config.defaultTtlMs)
}

async function agentTtlMs($: EngineInterface, config: Config): Promise<number> {
  return effectiveTtl(asBounds(await $.store.get('agentTtl')), config.agentTtlMs)
}

async function segmentPath($: EngineInterface, sessionId: string): Promise<string> {
  const state = (await $.env.get('XDG_STATE_HOME')) || `${await $.env.get('HOME')}/.local/state`
  return `${state}/harness/status/${sessionId}/cache-guard.json`
}

async function liveContext($: EngineInterface): Promise<number | undefined> {
  return (await $.session.usage()).context.tokens
}

async function writeSegment($: EngineInterface, config: Config): Promise<void> {
  const now = await $.clock.now()
  const segment = joinSegments(
    segmentFor(await read($, last), await liveContext($), now, await ttlMs($, config)),
    agentSegment(await read($, agents), await read($, listed), now, await agentTtlMs($, config)),
  )
  await $.fs.write(await segmentPath($, await $.session.id()), segmentFile(segment, await $.clock.now()))
}

async function showSegment($: EngineInterface, config: Config): Promise<void> {
  try {
    await writeSegment($, config)
  } catch (err) {
    $.ui.log(`cache-guard: could not write the status segment: ${String(err)}`, { to: 'debug' })
  }
}

// rmdir fails harmlessly while other mods' files remain, because the session folder is shared.
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

function listedAgent(info: AgentInfo) {
  return { id: info.id, type: info.type, description: info.description, status: info.status }
}

async function refreshAgents($: EngineInterface): Promise<void> {
  const list = (await $.agent.list()).map(listedAgent)
  const now = await $.clock.now()
  await update($, listed, () => list)
  await update($, agents, tracked => pruneTracks(tracked, now))
}

async function tick($: EngineInterface, config: Config): Promise<void> {
  try {
    await refreshAgents($)
  } catch (err) {
    $.ui.log(`cache-guard: could not list agents: ${String(err)}`, { to: 'debug' })
  }
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
  if (!seen) return
  await update($, last, () => seen.last)
  await $.store.set('ttl', seen.bounds)
  const miss = seen.miss
  if (!miss) return
  const kept = await update($, misses, list => [...list, miss].slice(-MISSES_KEPT))
  await $.store.set('misses', kept)
  $.ui.toast(missToast(miss))
}

async function observeAgent(
  $: EngineInterface,
  config: Config,
  agentId: string,
  startedAt: number,
  usage: TurnUsage,
): Promise<void> {
  const prev = (await read($, agents))[agentId] ?? null
  const seen = observeStep({
    prev,
    startedAt,
    now: await $.clock.now(),
    usage,
    bounds: asBounds(await $.store.get('agentTtl')),
    defaultTtlMs: config.agentTtlMs,
  })
  if (!seen) return
  const track = { ...seen.last, firstAt: prev?.firstAt ?? startedAt }
  await update($, agents, tracked => ({ ...tracked, [agentId]: track }))
  await $.store.set('agentTtl', seen.bounds)
  if (!seen.miss) return
  const miss = { ...seen.miss, agentId }
  const kept = await update($, misses, list => [...list, miss].slice(-MISSES_KEPT))
  await $.store.set('misses', kept)
  const type = (await $.agent.list()).find(a => a.id === agentId)?.type ?? 'subagent'
  $.ui.toast(agentMissToast(type, miss))
}

async function clearThenRestore($: EngineInterface, text: string): Promise<void> {
  try {
    await $.command.run({ command: 'clear' })
  } catch (err) {
    $.ui.toast(`Could not clear (${String(err)}); run /clear yourself.`)
    await $.prompt.fill({ text })
    return
  }
  await $.prompt.fill({ text: handoffPrompt(text) })
}

export const register: Register = (on, options) => {
  const config: Config = {
    defaultTtlMs: Number(options.ttlMinutes ?? 60) * MINUTE,
    agentTtlMs: Number(options.agentTtlMinutes ?? 5) * MINUTE,
    gateUsd: Number(options.gateUsd ?? 1),
  }
  let ticker: Timer | undefined

  on('session.start', async ($, e, next) => {
    const stored = asMisses(await $.store.get('misses'))
    await update($, misses, () => stored)
    await tick($, config)
    ticker?.cancel()
    ticker = $.clock.every(SEGMENT_EVERY_MS, () => void tick($, config))
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    // The ticker must survive a /clear because no session.start follows it to restart one.
    if (e.reason === 'clear') {
      await update($, last, () => null)
    } else {
      ticker?.cancel()
      ticker = undefined
    }
    await removeSegment($, e.sessionId)
    return next(e)
  })

  // Per-step usage, because turn.complete sums every request of the turn and a
  // cold first request would hide behind the warm reads of the steps after it.
  on('turn.step', async function* ($, e, next) {
    const startedAt = await $.clock.now()
    const response = yield* next(e)
    if (response.usage) {
      try {
        if (e.agentId === undefined) await observe($, config, startedAt, response.usage)
        else await observeAgent($, config, e.agentId, startedAt, response.usage)
      } catch (err) {
        $.ui.log(`cache-guard: could not record step usage: ${String(err)}`, { to: 'debug' })
      }
    }
    return response
  })

  on('turn.complete', async ($, e, next) => {
    await tick($, config)
    return next(e)
  })

  // Fails open because this is a cost warning: a broken guard must never eat a prompt.
  on('prompt.submit', async ($, e, next) => {
    // Attachments cannot be put back in the prompt box, so a prompt carrying them is never held.
    if (e.origin.kind !== 'composer' || e.turnId !== undefined || e.attachments) return next(e)
    const gate = gateDecision(
      await read($, last),
      await liveContext($),
      await $.clock.now(),
      await ttlMs($, config),
      config.gateUsd,
    )
    if (!gate) return next(e)

    const choice = await $.ui
      .ask(gateQuestion(gate), { header: 'Cold cache', options: [SEND, CLEAR, DRAFT] })
      .catch((err: unknown) => {
        $.ui.log(`cache-guard: cold cache question unanswered (${String(err)}), sending`, { to: 'debug' })
        return SEND
      })

    if (choice === CLEAR) {
      // $.command.run rejects inside a hook the turn waits on, so /clear runs once the prompt is dropped.
      $.clock.after(0, () => void clearThenRestore($, e.text))
      return { drop: 'Clearing; your prompt will be back in the box.' }
    }
    if (choice === DRAFT) {
      await $.prompt.fill({ text: e.text })
      return { drop: 'Kept as a draft; the prompt cache is still cold.' }
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const alerts = agentAlerts(
      await read($, agents),
      await read($, listed),
      await $.clock.now(),
      await agentTtlMs($, config),
      await read($, dismissed),
    )
    if (alerts.rows.length === 0) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {alerts.rows.map(row => (
          <Box key={row.key} flexDirection="row" flexWrap="wrap" columnGap={1}>
            <Text color="warning">{row.text}</Text>
            <Button
              key={`dismiss-${row.key}`}
              label="Dismiss"
              dimColor
              role="dismiss"
              onPress={() => update($, dismissed, keys => [...keys, row.key])}
            />
          </Box>
        ))}
        {alerts.more > 0 && <Text dimColor>+{alerts.more} more</Text>}
        {await next(e)}
      </Box>
    )
  })
}
