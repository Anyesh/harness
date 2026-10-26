export type ScopeStatus =
  | { kind: 'fresh' }
  | { kind: 'missing' }
  | { kind: 'stale'; ageHours: number }

export type WikiStatus = {
  devlogPath: string
  indexPath: string
  devlogWritten: boolean
  indexWritten: boolean
  pagesChanged: boolean
  latestWriteMs: number
}

export type Snapshot = {
  root: string | null
  isGit: boolean
  slug: string
  scope: ScopeStatus | null
  wiki: WikiStatus | null
  junk: string[]
  humanize: string | null
  ownit: string | null
  unattended: boolean
}

export type Armed = {
  scope: boolean
  wikiFired: boolean
  wikiAnchorTurn: number
  wikiAnchorEdits: number
  wikiSeenWriteMs: number
  cleanupReported: string[]
}

declare module 'claude-code' {
  interface PluginState {
    'nudge-band': {
      turns: number
      edits: number
      startedAt: number | null
      snapshot: Snapshot | null
      armed: Armed
      isHidden: boolean
    }
  }
}
