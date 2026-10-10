export type LastResponse = {
  at: number
  ctx: number
  model: string
}

export type TtlBounds = {
  warmMaxMs: number | null
  coldMinMs: number | null
}

export type Miss = {
  at: number
  gapMs: number
  tokens: number
  usd: number
  model: string
}

declare module 'claude-code' {
  interface PluginState {
    'cache-guard': {
      last: LastResponse | null
      misses: Miss[]
    }
  }
}
