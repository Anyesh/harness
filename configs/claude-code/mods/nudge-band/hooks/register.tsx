import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import { probe } from './probe'
import type { ProbeIO } from './probe'
import { countTurnEdits, decide, initialArmed, modeLabels, wikiMissing } from './rules'
import type { Snapshot } from '../types'

const turns = atom({ plugin: 'nudge-band', key: 'turns' } as const, 0)
const edits = atom({ plugin: 'nudge-band', key: 'edits' } as const, 0)
const startedAt = atom({ plugin: 'nudge-band', key: 'startedAt' } as const, null)
const snapshot = atom({ plugin: 'nudge-band', key: 'snapshot' } as const, null)
const armed = atom({ plugin: 'nudge-band', key: 'armed' } as const, initialArmed)
const isHidden = atom({ plugin: 'nudge-band', key: 'isHidden' } as const, false)

async function sessionStart($: EngineInterface): Promise<number> {
  const known = await read($, startedAt)
  if (known !== null) return known
  const now = await $.clock.now()
  await update($, startedAt, () => now)
  return now
}

function probeIO($: EngineInterface): ProbeIO {
  return {
    exists: path => $.fs.exists(path),
    stat: path => $.fs.stat(path),
    read: path => $.fs.read(path),
    run: (argv, cwd) => $.process.run(argv, cwd ? { cwd } : undefined),
    vars: async () => ({
      home: await $.env.get('HOME'),
      configDir: await $.env.get('CLAUDE_CONFIG_DIR'),
      unattended: await $.env.get('HARNESS_UNATTENDED'),
    }),
    cwd: () => $.session.cwd(),
    now: () => $.clock.now(),
  }
}

async function refresh($: EngineInterface): Promise<Snapshot> {
  const snap = await probe(probeIO($), await sessionStart($))
  await update($, snapshot, () => snap)
  return snap
}

function cleanupDraft(junk: readonly string[]): string {
  return `Delete these untracked files if they are leftover scratch artifacts, and keep anything still in use: ${junk.join(', ')}`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await refresh($)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    const turn = await update($, turns, n => n + 1)
    const snap = await refresh($)
    const decision = decide({ turns: turn, edits: await read($, edits), snapshot: snap, armed: await read($, armed) })
    await update($, armed, () => decision.armed)
    if (decision.messages.length === 0) return next(e)
    return next({ ...e, context: [...(e.context ?? []), ...decision.messages] })
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const added = countTurnEdits(await $.session.messages())
      if (added > 0) await update($, edits, n => n + added)
      await refresh($)
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const snap = await read($, snapshot)
    if (e.props.hasSurvey || snap === null || (await read($, isHidden))) return next(e)

    const scope = snap.scope && snap.scope.kind !== 'fresh' ? snap.scope : null
    const unwritten = snap.wiki ? wikiMissing(snap.wiki).join(', ') : ''
    const wiki = unwritten ? snap.wiki : null
    const junk = snap.junk
    if (!scope && !wiki && junk.length === 0) return next(e)

    const { Box, Button, Text } = $.ui.resolve(e)
    const fill = (text: string) => () => void $.prompt.fill({ text })

    const row = (
      <Box flexDirection="row" flexWrap="wrap" columnGap={1}>
        {scope && (
          <Text dimColor>scope: {scope.kind === 'missing' ? 'missing' : `${scope.ageHours}h old`}</Text>
        )}
        {scope && <Button key="scope" label="Write scope" dimColor onPress={fill('/scope')} />}
        {wiki && <Text dimColor>wiki: {unwritten} not written</Text>}
        {wiki && <Button key="wiki" label="Log it" dimColor onPress={fill('/devlog')} />}
        {junk.length > 0 && <Text dimColor>junk: {junk.length} {junk.length === 1 ? 'file' : 'files'}</Text>}
        {junk.length > 0 && <Button key="junk" label="Clean up" dimColor onPress={fill(cleanupDraft(junk))} />}
        <Button key="hide" label="Hide" dimColor role="dismiss" onPress={() => update($, isHidden, () => true)} />
      </Box>
    )
    return (
      <Box flexDirection="column">
        {row}
        {await next(e)}
      </Box>
    )
  })

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const snap = await read($, snapshot)
    const ours = snap ? modeLabels(snap) : []
    if (ours.length === 0) return next(e)
    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, ...ours] } })
  })
}
