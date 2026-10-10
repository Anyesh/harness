import type { Block } from '../types'

const DETAIL_CHARS = 80

export type Tone = 'normal' | 'warn'
export type Segment = { text: string; tone: Tone }

// The script path names the guard better than [hook:global], because several pre-edit checks share that tag.
export function guardName(reason: string): string {
  const named = /BLOCKED by ([\w-]+)/.exec(reason) ?? /\[hook:([\w-]+)\]/.exec(reason)
  if (named?.[1] && named[1] !== 'global') return named[1]
  const script = /\/([\w-]+)\.(?:sh|py|js)\b/.exec(reason)
  return script?.[1] ?? 'guard'
}

export function blockDetail(reason: string): string {
  const marker = /BLOCKED(?: by [\w-]+)?:\s*/.exec(reason)
  const rest = marker ? reason.slice(marker.index + marker[0].length) : reason
  const line = (rest.split('\n')[0] ?? '').trim()
  return line.length > DETAIL_CHARS ? `${line.slice(0, DETAIL_CHARS - 1)}…` : line
}

export function blockSegment(blocks: readonly Block[]): Segment | null {
  if (blocks.length === 0) return null
  const text = blocks.length === 1 ? '1 block' : `${blocks.length} blocks`
  return { text, tone: blocks.some(b => b.agentId !== undefined) ? 'warn' : 'normal' }
}

export function blockToast(block: Block, agentType: string): string {
  return `${block.guard} blocked ${agentType}'s ${block.tool}: ${block.detail}`
}

// The format must match what statusline.sh reads; tests/test_statusline.sh pins that side.
export function segmentFile(segment: Segment | null, at: number): string {
  return segment ? JSON.stringify({ text: segment.text, tone: segment.tone, at }) : ''
}
