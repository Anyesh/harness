import type { SessionCompactTrigger, SessionMessage } from 'claude-code'

export type DigestBlock = { text: string; lines: number }

export const SECTIONS = [
  { title: 'GOAL', ask: 'What the user wants done overall, in one or two sentences.' },
  {
    title: 'NEXT STEP',
    ask: 'The single next action, concrete enough to start without asking. The latest user message wins over an older plan: if the user changed direction after the plan was written, the next step follows the change.',
  },
  { title: 'DECISIONS AND REASONS', ask: 'Each choice made in this session with the reason for it, one bullet each.' },
  { title: 'RULED OUT', ask: 'Approaches tried or considered and dropped, with why, so they are not retried.' },
  { title: 'OPEN QUESTIONS', ask: 'What is still undecided or waiting on the user; "none" if nothing is.' },
  { title: 'VERIFY', ask: 'The command or check that proves the work is done.' },
] as const

const CLASSIC = /^\s*classic\b\s*/

export function classicRequest(
  trigger: SessionCompactTrigger,
  instructions: string | undefined,
): { instructions: string | undefined } | undefined {
  if (trigger !== 'manual' || instructions === undefined || !CLASSIC.test(instructions)) return undefined
  const rest = instructions.replace(CLASSIC, '').trim()
  return { instructions: rest === '' ? undefined : rest }
}

export function forkPrompt(instructions?: string): string {
  const sections = SECTIONS.map(s => `## ${s.title}\n${s.ask}`).join('\n')
  const lines = [
    'This conversation is about to be compacted. Everything above will be replaced by a handoff: your reply, followed by a digest built from the transcript and git without a model.',
    'That digest already lists the files touched, the commits and git status, the last approved plan, the newest turns verbatim and an index of every user prompt, so do not repeat any of it. Write only what it cannot recover: intent, reasons and dead ends.',
    'The latest user message wins over an older plan.',
    '',
    'Use no tools. Reply with the handoff only, no preamble, in exactly these sections:',
    '',
    sections,
    '',
    'Keep it under 600 words.',
  ]
  if (instructions?.trim()) lines.push('', `The user asked this compaction to: ${instructions.trim()}`, 'Follow that in what you keep and stress.')
  return lines.join('\n')
}

export function reasoningOutline(instructions?: string): string {
  const outline = `Make the summary also cover, under these headings: ${SECTIONS.map(s => s.title).join(', ')}. The latest user message wins over an older plan.`
  return instructions?.trim() ? `${instructions.trim()}\n\n${outline}` : outline
}

export function digestBlock(digestText: string): DigestBlock {
  const cut = digestText.search(/^## Prompt index$/m)
  const text = (cut === -1 ? digestText : digestText.slice(0, cut)).trimEnd()
  return { text, lines: text.split('\n').length }
}

// The "[handoff] " prefix must stay as is because handoff-digest.sh drops user messages that start with it,
// so a later digest does not count an earlier handoff as a prompt.
function header(digestPath: string, what: string): string {
  return `[handoff] ${what} The full digest, with an index of every user prompt, is at ${digestPath}; read or grep it when an older prompt matters.`
}

export function handoffMessage(args: {
  reasoning: string
  block: DigestBlock
  digestPath: string
  trigger: SessionCompactTrigger
}): string {
  const what = `The earlier conversation was replaced by this handoff at compaction (trigger: ${args.trigger}). The reasoning was written by a fork of the session; the facts below it come from the transcript and git.`
  return [header(args.digestPath, what), '', args.reasoning.trim(), '', args.block.text].join('\n')
}

export function withDigest(core: readonly SessionMessage[], block: DigestBlock, digestPath: string): SessionMessage[] {
  const what = 'The summary above is the built-in one; these facts come from the transcript and git.'
  return [...core, { role: 'user', text: [header(digestPath, what), '', block.text].join('\n'), toolUses: [] }]
}

export function nextHandoffPath(digestPath: string, names: readonly string[]): string {
  const slash = digestPath.lastIndexOf('/')
  const dir = digestPath.slice(0, slash)
  const session = digestPath.slice(slash + 1).replace(/\.md$/, '')
  const taken = names
    .filter(n => n.startsWith(`${session}.handoff-`))
    .map(n => Number(/\.handoff-(\d+)\.md$/.exec(n)?.[1] ?? 0))
  return `${dir}/${session}.handoff-${Math.max(0, ...taken) + 1}.md`
}
