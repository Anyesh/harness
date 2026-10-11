export type SpinnerFix = 'idle' | 'compacted' | 'stale'

declare module 'claude-code' {
  interface PluginState {
    handoff: {
      spinnerFix: SpinnerFix
    }
  }
}
