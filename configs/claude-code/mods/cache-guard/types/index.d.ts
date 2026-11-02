export type StepRecord = {
  at: number
  ctx: number
  model: string
}

export type LastResponse = StepRecord & {
  sessionId: string
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
  agentId?: string
}

export type AgentTrack = StepRecord & {
  firstAt: number
}

export type ListedAgent = {
  id: string
  type: string
  description: string
  // AgentStatus spelled out, because the validator requires a contract with no imports.
  status: 'pending' | 'running' | 'waiting' | 'idle' | 'completed' | 'failed' | 'killed'
}

declare module 'claude-code' {
  interface PluginState {
    'cache-guard': {
      last: LastResponse | null
      misses: Miss[]
      agents: Record<string, AgentTrack>
      listed: ListedAgent[]
      dismissed: string[]
    }
  }
}
