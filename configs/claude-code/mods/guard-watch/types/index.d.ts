export type Block = {
  at: number
  guard: string
  tool: string
  detail: string
  agentId?: string
}

declare module 'claude-code' {
  interface PluginState {
    'guard-watch': {
      blocks: Block[]
    }
  }
}
