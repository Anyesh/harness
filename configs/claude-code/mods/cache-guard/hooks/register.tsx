import { atom, read, update } from 'claude-code'
import type { AgentInfo, EngineInterface, Register, Timer, TurnStepInput, TurnStepResult, TurnUsage } from 'claude-code'

import type { LastResponse } from '../types'

import {
  agentAlerts,
  agentMissToast,
  agentSegment,
  MINUTE,
  MISSES_KEPT,
  asBounds,
  asMisses,
  asStepRecord,
  effectiveTtl,
  gateDecision,
  gateQuestion,
  handoffPrompt,
  isCrewPrompt,
  isLastKey,
  joinSegments,
  lastKey,
  missToast,
  observeStep,
  pruneLastKeys,
  pruneTracks,
  segmentFile,
  segmentFor,
  STEP_HANDOFF,
  waitsOnPerson,
  STOP_NOTICE,
} from './rules'

const last = atom({ plugin: 'cache-guard', key: 'last' } as const, null)
const misses = atom({ plugin: 'cache-guard', key: 'misses' } as const, [])
const agents = atom({ plugin: 'cache-guard', key: 'agents' } as const, {})
const listed = atom({ plugin: 'cache-guard', key: 'listed' } as const, [])
const dismissed = atom({ plugin: 'cache-guard', key: 'dismissed' } as const, [])

const SEND = 'Send anyway'
const CLEAR = 'Clear and hand off'
const DRAFT = 'Keep as draft'
const STOP = 'Stop here'
const SEGMENT_EVERY_MS = 30_000
const CREW_TURNS_KEPT = 8

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

// The atom holds one session's response and dies with the process, so any other session reads the store.
async function currentLast($: EngineInterface): Promise<LastResponse | null> {
  const sessionId = await $.session.id()
  const held = await read($, last)
  if (held?.sessionId === sessionId) return held
  const stored = asStepRecord(await $.store.get(lastKey(sessionId)))
  const found = stored ? { ...stored, sessionId } : null
  await update($, last, () => found)
  return found
}

async function pruneLast($: EngineInterface): Promise<void> {
  const keys = (await $.store.keys()).filter(isLastKey)
  const entries = await Promise.all(keys.map(async key => [key, await $.store.get(key)] as const))
  for (const key of pruneLastKeys(entries, lastKey(await $.session.id()))) await $.store.delete(key)
}

async function writeSegment($: EngineInterface, config: Config): Promise<void> {
  const now = await $.clock.now()
  const segment = joinSegments(
    segmentFor(await currentLast($), await liveContext($), now, await ttlMs($, config)),
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
  const sessionId = await $.session.id()
  const seen = observeStep({
    prev: await currentLast($),
    startedAt,
    now: await $.clock.now(),
    usage,
    bounds: asBounds(await $.store.get('ttl')),
    defaultTtlMs: config.defaultTtlMs,
  })
  if (!seen) return
  await update($, last, () => ({ ...seen.last, sessionId }))
  await $.store.set(lastKey(sessionId), seen.last)
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

async function clearThenRestore($: EngineInterface, handoff: string, unclearedText?: string): Promise<void> {
  try {
    await $.command.run({ command: 'clear' })
  } catch (err) {
    $.ui.toast(`Could not clear (${String(err)}); run /clear yourself.`)
    if (unclearedText !== undefined) await $.prompt.fill({ text: unclearedText })
    return
  }
  await $.prompt.fill({ text: handoff })
}

// Null when the cache is warm or re-writing it costs less than the option allows.
async function coldChoice($: EngineInterface, config: Config, options: readonly string[]): Promise<string | null> {
  const gate = gateDecision(
    await currentLast($),
    await liveContext($),
    await $.clock.now(),
    await ttlMs($, config),
    config.gateUsd,
  )
  if (!gate) return null
  return $.ui.ask(gateQuestion(gate), { header: 'Cold cache', options }).catch((err: unknown) => {
    $.ui.log(`cache-guard: cold cache question unanswered (${String(err)}), sending`, { to: 'debug' })
    return SEND
  })
}

type GateMarks = { waited: boolean; crewTurns: string[] }

// Step 0 is left to the submit gate, which knows the prompt's origin and attachments.
// Fails open like the submit gate: a broken guard must never hold a turn.
async function stepChoice($: EngineInterface, config: Config, marks: GateMarks, e: TurnStepInput): Promise<string | null> {
  const afterWait = marks.waited
  marks.waited = false
  if (!afterWait || e.index === 0 || marks.crewTurns.includes(e.turnId)) return null
  try {
    return await coldChoice($, config, [SEND, CLEAR, STOP])
  } catch (err) {
    $.ui.log(`cache-guard: step gate failed (${String(err)}), sending`, { to: 'debug' })
    return null
  }
}

function unsent(e: TurnStepInput): TurnStepResult {
  return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: null, usage: null }
}

export const register: Register = (on, options) => {
  const config: Config = {
    defaultTtlMs: Number(options.ttlMinutes ?? 60) * MINUTE,
    agentTtlMs: Number(options.agentTtlMinutes ?? 5) * MINUTE,
    gateUsd: Number(options.gateUsd ?? 1),
  }
  let ticker: Timer | undefined
  const marks: GateMarks = { waited: false, crewTurns: [] }

  on('session.start', async ($, e, next) => {
    const stored = asMisses(await $.store.get('misses'))
    await update($, misses, () => stored)
    try {
      await pruneLast($)
    } catch (err) {
      $.ui.log(`cache-guard: could not prune stored responses: ${String(err)}`, { to: 'debug' })
    }
    await tick($, config)
    ticker?.cancel()
    ticker = $.clock.every(SEGMENT_EVERY_MS, () => void tick($, config))
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    // The ticker must survive a /clear because no session.start follows it to restart one.
    if (e.reason !== 'clear') {
      ticker?.cancel()
      ticker = undefined
    }
    await removeSegment($, e.sessionId)
    return next(e)
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (waitsOnPerson(e, verdict, next.origin)) marks.waited = true
    return verdict
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined && isCrewPrompt(e.text)) {
      marks.crewTurns.push(e.turnId)
      marks.crewTurns.splice(0, marks.crewTurns.length - CREW_TURNS_KEPT)
    }
    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined) {
      const choice = await stepChoice($, config, marks, e)
      if (choice === STOP) {
        $.ui.toast(STOP_NOTICE)
        return unsent(e)
      }
      if (choice === CLEAR) {
        // $.command.run rejects inside a hook the turn waits on, so /clear runs once the step is answered.
        $.clock.after(0, () => void clearThenRestore($, STEP_HANDOFF))
        return unsent(e)
      }
    }
    // Per-step usage, because turn.complete sums every request of the turn and a
    // cold first request would hide behind the warm reads of the steps after it.
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
    if (e.origin.kind !== 'composer' || e.turnId !== undefined || e.attachments || isCrewPrompt(e.text)) {
      return next(e)
    }
    const choice = await coldChoice($, config, [SEND, CLEAR, DRAFT])
    if (choice === CLEAR) {
      // $.command.run rejects inside a hook the turn waits on, so /clear runs once the prompt is dropped.
      $.clock.after(0, () => void clearThenRestore($, handoffPrompt(e.text), e.text))
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
