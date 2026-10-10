import type { ModelUsage, TurnUsage } from 'claude-code'

import type { LastResponse, Miss, TtlBounds } from '../types'

export const MINUTE = 60_000
export const MISSES_KEPT = 20
const MILLION = 1_000_000
const FIVE_MINUTES = 5 * MINUTE
const MIN_MISS_TOKENS = 50_000
const MIN_STATUS_CTX = 20_000

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

export function compactUsd(model: string, tokens: number): number {
  return (tokens * priceFor(model, tokens).input) / MILLION
}

export type StepKind = 'warm' | 'cold'

export function classifyStep(prevCtx: number, usage: ModelUsage): StepKind | null {
  if (prevCtx <= 0) return null
  if (usage.cache_read_input_tokens >= 0.5 * prevCtx) return 'warm'
  if (usage.cache_read_input_tokens < 0.1 * prevCtx && usage.cache_creation_input_tokens >= 0.5 * prevCtx) return 'cold'
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

export function observeStep(o: StepObservation): Observed {
  const last = { at: o.now, ctx: contextOf(o.usage), model: o.usage.model }
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

export type Gate = { idleMs: number; tokens: number; rewriteUsd: number; compactUsd: number }

export function gateDecision(last: LastResponse | null, now: number, ttlMs: number, gateUsd: number): Gate | null {
  if (!last) return null
  const idleMs = now - last.at
  if (idleMs < ttlMs) return null
  const rewrite = rewriteUsd(last.model, last.ctx, ttlMs)
  if (rewrite < gateUsd) return null
  return { idleMs, tokens: last.ctx, rewriteUsd: rewrite, compactUsd: compactUsd(last.model, last.ctx) }
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

export function segmentFor(last: LastResponse | null, now: number, ttlMs: number): Segment | null {
  if (!last || last.ctx < MIN_STATUS_CTX) return null
  const left = last.at + ttlMs - now
  if (left > 0) return { text: `cache ${formatDuration(left)}`, tone: 'normal' }
  return { text: `cache cold ≈ ${formatUsd(rewriteUsd(last.model, last.ctx, ttlMs))}`, tone: 'warn' }
}

// The format must match what statusline.sh reads; tests/test_statusline.sh pins that side.
export function segmentFile(segment: Segment | null, at: number): string {
  return segment ? JSON.stringify({ text: segment.text, tone: segment.tone, at }) : ''
}

export function gateQuestion(gate: Gate): string {
  return (
    `The prompt cache has likely expired (idle ${formatDuration(gate.idleMs)}). ` +
    `Sending re-writes ~${formatTokens(gate.tokens)} tokens (≈ ${formatUsd(gate.rewriteUsd)}); ` +
    `compacting first reads them once (≈ ${formatUsd(gate.compactUsd)}). What now?`
  )
}

export function missToast(miss: Miss): string {
  return (
    `Cache went cold after ${formatDuration(miss.gapMs)}: ` +
    `re-wrote ${formatTokens(miss.tokens)} tokens (≈ ${formatUsd(miss.usd)} at API prices)`
  )
}
