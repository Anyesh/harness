import type { ModelUsage, TurnUsage } from 'claude-code'

import type { AgentTrack, LastResponse, ListedAgent, Miss, TtlBounds } from '../types'

export const MINUTE = 60_000
export const MISSES_KEPT = 20
const MILLION = 1_000_000
const FIVE_MINUTES = 5 * MINUTE
const MIN_MISS_TOKENS = 50_000
const MIN_STATUS_CTX = 20_000
const MIN_AGENT_ALERT_TOKENS = 50_000
const LONG_AGENT_MS = 60 * MINUTE
const MAX_ALERT_ROWS = 3
const TRACK_KEEP_MS = 24 * 60 * MINUTE

export type Prices = { input: number; write1h: number; write5m: number; read: number }

type PriceRow = { prefix: string; prices: Prices; tier?: { above: number; factor: number } }

const OPUS_5_5: PriceRow = { prefix: 'claude-opus-5-5', prices: { input: 4, write1h: 8, write5m: 5, read: 0.2 } }

const PRICE_ROWS: readonly PriceRow[] = [
  OPUS_5_5,
  { prefix: 'claude-sonnet-5-5', prices: { input: 2, write1h: 4, write5m: 2.5, read: 0.2 } },
  { prefix: 'claude-fable-5-1', prices: { input: 10, write1h: 20, write5m: 12.5, read: 0.25 } },
  {
    prefix: 'claude-haiku-5-5',
    prices: { input: 0.1, write1h: 0.2, write5m: 0.125, read: 0.01 },
    tier: { above: 100_000, factor: 5 },
  },
]

// Bedrock and Vertex ids carry a region or vendor prefix, so matching starts at "claude-".
export function priceFor(model: string, tokens: number): Prices {
  const id = model.slice(Math.max(0, model.indexOf('claude-')))
  const row = PRICE_ROWS.find(r => id.startsWith(r.prefix)) ?? OPUS_5_5
  if (!row.tier || tokens <= row.tier.above) return row.prices
  const { factor } = row.tier
  const p = row.prices
  return { input: p.input * factor, write1h: p.write1h * factor, write5m: p.write5m * factor, read: p.read * factor }
}

export function contextOf(usage: ModelUsage): number {
  return usage.input_tokens + usage.cache_read_input_tokens + usage.cache_creation_input_tokens
}

// A cache that lives longer than five minutes is the 1-hour cache, which writes at the higher rate.
export function rewriteUsd(model: string, tokens: number, ttlMs: number): number {
  const prices = priceFor(model, tokens)
  return (tokens * (ttlMs > FIVE_MINUTES ? prices.write1h : prices.write5m)) / MILLION
}

export type StepKind = 'warm' | 'cold'

export function classifyStep(prevCtx: number, usage: ModelUsage): StepKind | null {
  if (prevCtx <= 0) return null
  if (usage.cache_read_input_tokens >= 0.5 * prevCtx) return 'warm'
  // A cold step may still read some cache, because the system and tools prefix can stay cached on its own, a large share in a subagent.
  if (usage.cache_creation_input_tokens >= 0.5 * prevCtx) return 'cold'
  return null
}

export const noBounds: TtlBounds = { warmMaxMs: null, coldMinMs: null }

// Invariant: warmMaxMs < coldMinMs. An observation that breaks it (a plan or TTL change) replaces the bounds.
export function learnTtl(bounds: TtlBounds, kind: StepKind, gapMs: number): TtlBounds {
  if (kind === 'warm') {
    if (bounds.coldMinMs !== null && gapMs >= bounds.coldMinMs) return { warmMaxMs: gapMs, coldMinMs: null }
    return { ...bounds, warmMaxMs: Math.max(bounds.warmMaxMs ?? 0, gapMs) }
  }
  if (bounds.warmMaxMs !== null && gapMs <= bounds.warmMaxMs) return { warmMaxMs: null, coldMinMs: gapMs }
  return { ...bounds, coldMinMs: Math.min(bounds.coldMinMs ?? gapMs, gapMs) }
}

export function effectiveTtl(bounds: TtlBounds, defaultMs: number): number {
  let ttl = defaultMs
  if (bounds.warmMaxMs !== null) ttl = Math.max(ttl, bounds.warmMaxMs)
  if (bounds.coldMinMs !== null) ttl = Math.min(ttl, bounds.coldMinMs)
  return ttl
}

function finiteOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

export function asBounds(stored: unknown): TtlBounds {
  if (typeof stored !== 'object' || stored === null) return noBounds
  const { warmMaxMs, coldMinMs } = stored as Record<string, unknown>
  return { warmMaxMs: finiteOrNull(warmMaxMs), coldMinMs: finiteOrNull(coldMinMs) }
}

export function asMisses(stored: unknown): Miss[] {
  if (!Array.isArray(stored)) return []
  return stored
    .filter((m): m is Miss => typeof m === 'object' && m !== null && typeof (m as Miss).tokens === 'number')
    .slice(-MISSES_KEPT)
}

export type StepObservation = {
  prev: LastResponse | null
  startedAt: number
  now: number
  usage: TurnUsage
  bounds: TtlBounds
  defaultTtlMs: number
}

export type Observed = { last: LastResponse; bounds: TtlBounds; miss: Miss | null }

// A response can report zero usage (a trailing empty entry), and keeping it would erase the context the next step is classified against.
export function observeStep(o: StepObservation): Observed | null {
  const ctx = contextOf(o.usage)
  if (ctx <= 0) return null
  const last = { at: o.now, ctx, model: o.usage.model }
  const unchanged = { last, bounds: o.bounds, miss: null }
  // A new model starts its own cache, so its first step says nothing about expiry.
  if (!o.prev || o.prev.model !== o.usage.model) return unchanged
  const gapMs = o.startedAt - o.prev.at
  const kind = classifyStep(o.prev.ctx, o.usage)
  // A cold step within minutes of the last response means the prefix changed (tools, system prompt), not expiry.
  if (kind === null || (kind === 'cold' && gapMs < FIVE_MINUTES)) return unchanged
  const bounds = learnTtl(o.bounds, kind, gapMs)
  const tokens = o.usage.cache_creation_input_tokens
  if (kind === 'warm' || tokens < MIN_MISS_TOKENS) return { last, bounds, miss: null }
  const usd = rewriteUsd(o.usage.model, tokens, effectiveTtl(bounds, o.defaultTtlMs))
  return { last, bounds, miss: { at: o.now, gapMs, tokens, usd, model: o.usage.model } }
}

export type Gate = { idleMs: number; tokens: number; rewriteUsd: number }

// ctx is the engine's live context size, absent right after a compaction or a clear; last only says when and on which model.
export function gateDecision(
  last: LastResponse | null,
  ctx: number | undefined,
  now: number,
  ttlMs: number,
  gateUsd: number,
): Gate | null {
  if (!last || !ctx) return null
  const idleMs = now - last.at
  if (idleMs < ttlMs) return null
  const rewrite = rewriteUsd(last.model, ctx, ttlMs)
  if (rewrite < gateUsd) return null
  return { idleMs, tokens: ctx, rewriteUsd: rewrite }
}

export function isCrewPrompt(text: string): boolean {
  return text.startsWith('[crew] ')
}

export function formatTokens(tokens: number): string {
  if (tokens >= MILLION) return `${(tokens / MILLION).toFixed(1)}M`
  if (tokens >= 1000) return `${Math.round(tokens / 1000)}k`
  return String(tokens)
}

export function formatUsd(usd: number): string {
  return usd < 0.005 ? '<$0.01' : `$${usd.toFixed(2)}`
}

export function formatDuration(ms: number): string {
  if (ms < MINUTE) return `${Math.max(0, Math.floor(ms / 1000))}s`
  return `${Math.floor(ms / MINUTE)}m`
}

export type Tone = 'normal' | 'warn'
export type Segment = { text: string; tone: Tone }

export function segmentFor(last: LastResponse | null, ctx: number | undefined, now: number, ttlMs: number): Segment | null {
  if (!last || ctx === undefined || ctx < MIN_STATUS_CTX) return null
  const left = last.at + ttlMs - now
  if (left > 0) return { text: `cache ${formatDuration(left)}`, tone: 'normal' }
  return { text: `cache cold ≈ ${formatUsd(rewriteUsd(last.model, ctx, ttlMs))}`, tone: 'warn' }
}

// The format must match what statusline.sh reads; tests/test_statusline.sh pins that side.
export function segmentFile(segment: Segment | null, at: number): string {
  return segment ? JSON.stringify({ text: segment.text, tone: segment.tone, at }) : ''
}

export function gateQuestion(gate: Gate): string {
  return (
    `The prompt cache has likely expired (idle ${formatDuration(gate.idleMs)}). ` +
    `Sending re-writes ~${formatTokens(gate.tokens)} tokens (≈ ${formatUsd(gate.rewriteUsd)}); ` +
    `clearing hands off to a fresh session with the digest and re-writes nothing. What now?`
  )
}

// The digest path is not repeated here because the SessionStart:clear hook already puts it in the new session's context.
export function handoffPrompt(text: string): string {
  return `Continue from the previous session's handoff digest.\n\n${text}`
}

export function missToast(miss: Miss): string {
  return (
    `Cache went cold after ${formatDuration(miss.gapMs)}: ` +
    `re-wrote ${formatTokens(miss.tokens)} tokens (≈ ${formatUsd(miss.usd)} at API prices)`
  )
}

const ENDED: ReadonlySet<ListedAgent['status']> = new Set(['completed', 'failed', 'killed'])
const RESTING: ReadonlySet<ListedAgent['status']> = new Set(['idle', 'waiting'])

function isLive(agent: ListedAgent): boolean {
  return !ENDED.has(agent.status)
}

function isCold(agent: ListedAgent, track: AgentTrack | undefined, now: number, ttlMs: number): track is AgentTrack {
  return track !== undefined && RESTING.has(agent.status) && now - track.at >= ttlMs
}

export type AgentAlert = { key: string; text: string }

// An idle alert is keyed by the agent's last response so that a dismissal lasts only until the agent works and rests again.
export function agentAlerts(
  agents: Readonly<Record<string, AgentTrack>>,
  listed: readonly ListedAgent[],
  now: number,
  ttlMs: number,
  dismissed: readonly string[],
): { rows: AgentAlert[]; more: number } {
  const alerts: AgentAlert[] = []
  for (const agent of listed) {
    const track = agents[agent.id]
    if (!track || !isLive(agent)) continue
    const label = `${agent.type} "${agent.description}"`
    if (isCold(agent, track, now, ttlMs) && track.ctx >= MIN_AGENT_ALERT_TOKENS) {
      const usd = formatUsd(rewriteUsd(track.model, track.ctx, ttlMs))
      alerts.push({
        key: `${agent.id}@${track.at}`,
        text: `${label} idle ${formatDuration(now - track.at)} · resuming re-writes ${formatTokens(track.ctx)} ≈ ${usd}`,
      })
    } else if (now - track.firstAt >= LONG_AGENT_MS) {
      alerts.push({ key: `${agent.id}:long`, text: `${label} has run ${formatDuration(now - track.firstAt)}` })
    }
  }
  const open = alerts.filter(alert => !dismissed.includes(alert.key))
  return { rows: open.slice(0, MAX_ALERT_ROWS), more: Math.max(0, open.length - MAX_ALERT_ROWS) }
}

export function agentSegment(
  agents: Readonly<Record<string, AgentTrack>>,
  listed: readonly ListedAgent[],
  now: number,
  ttlMs: number,
): Segment | null {
  const live = listed.filter(isLive)
  if (live.length === 0) return null
  const cold = live.filter(agent => isCold(agent, agents[agent.id], now, ttlMs)).length
  if (cold === 0) return { text: `agents ${live.length}`, tone: 'normal' }
  return { text: `agents ${live.length} · ${cold} cold`, tone: 'warn' }
}

// Tracks age out by time, not by listing, because ended agents leave $.agent.list within a minute yet can be resumed much later.
export function pruneTracks(tracks: Readonly<Record<string, AgentTrack>>, now: number): Record<string, AgentTrack> {
  return Object.fromEntries(Object.entries(tracks).filter(([, track]) => now - track.at < TRACK_KEEP_MS))
}

export function joinSegments(...segments: (Segment | null)[]): Segment | null {
  const shown = segments.filter((s): s is Segment => s !== null)
  if (shown.length === 0) return null
  return { text: shown.map(s => s.text).join(' · '), tone: shown.some(s => s.tone === 'warn') ? 'warn' : 'normal' }
}

export function agentMissToast(type: string, miss: Miss): string {
  return (
    `Agent ${type} went cold after ${formatDuration(miss.gapMs)}: ` +
    `re-wrote ${formatTokens(miss.tokens)} tokens (≈ ${formatUsd(miss.usd)})`
  )
}
