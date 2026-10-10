import type { Armed, ScopeStatus, Snapshot } from '../types'

export const THRESHOLDS = {
  scopeTurn: 10,
  scopeFreshMs: 2 * 3_600_000,
  wikiFirstTurn: 5,
  wikiRepeatEdits: 3,
  wikiRepeatTurns: 10,
  cleanupTurn: 5,
  cleanupListMax: 10,
} as const

export const initialArmed: Armed = {
  scope: true,
  wikiFired: false,
  wikiAnchorTurn: 0,
  wikiAnchorEdits: 0,
  wikiSeenWriteMs: 0,
  cleanupReported: [],
}

const PROTECTED_DOCS = new Set([
  'readme.md', 'readme.txt', 'changelog.md', 'contributing.md', 'license', 'license.md',
  'license.txt', 'security.md', 'code_of_conduct.md', 'authors.md', 'maintainers.md',
  'notice.md', 'claude.md', 'agents.md', '.scope.md',
])

const ROOT_SCRATCH_NAMES = new Set([
  'plan.md', 'plans.md', 'handover.md', 'handoff.md', 'product.md', 'prd.md', 'notes.md',
  'note.md', 'scratch.md', 'summary.md', 'implementation.md', 'implementation_plan.md',
  'implementation-plan.md', 'changes.md', 'review.md', 'analysis.md', 'walkthrough.md',
  'brainstorm.md', 'ideas.md', 'draft.md', 'worklog.md', 'progress.md', 'status.md',
  'report.md', 'findings.md', 'investigation.md', 'todo.md', 'tasks.md', 'out.txt',
  'output.txt', 'debug.txt', 'dump.txt',
])

const ROOT_SCRATCH_PATTERNS = [/\.plan\.md$/, /\.notes\.md$/, /\.scratch\.md$/, /^scratch\./, /^tmp\./, /^debug\./]
const ANY_DEPTH_SUFFIXES = /(\.tmp|\.temp|\.bak|\.orig|\.rej|\.swp|\.swo|~|\.log)$/
const ANY_DEPTH_NAMES = new Set(['nohup.out', 'core'])
const SCRATCH_DIRS = /(^|\/)(screenshots|screenshot|scratch|tmp)\/|^\.scratch\/|^__scratch__\//
const ROOT_IMAGES = /\.(png|jpg|jpeg|gif|webp|bmp)$/

export const EDIT_TOOLS = new Set(['Write', 'Edit', 'NotebookEdit', 'mcp__verdant__write', 'mcp__verdant__edit'])

export function isJunk(path: string): boolean {
  const base = path.slice(path.lastIndexOf('/') + 1)
  const lower = base.toLowerCase()
  if (PROTECTED_DOCS.has(lower)) return false
  const atRoot = !path.includes('/')
  if (atRoot && (ROOT_SCRATCH_NAMES.has(lower) || ROOT_SCRATCH_PATTERNS.some(p => p.test(lower)))) return true
  if (ANY_DEPTH_SUFFIXES.test(lower) || ANY_DEPTH_NAMES.has(lower)) return true
  if (SCRATCH_DIRS.test(path)) return true
  return atRoot && ROOT_IMAGES.test(base)
}

export function projectSlug(root: string): string {
  const base = root.replace(/\/+$/, '').split('/').pop() ?? ''
  return base.toLowerCase().replace(/[^a-z0-9]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '')
}

export function isToolingDir(root: string, home: string): boolean {
  const base = root.split('/').pop() ?? ''
  return [`${home}/.cursor`, `${home}/.claude`, `${home}/.codex`].includes(root) || base === '.cursor' || base === '.claude'
}

export function scopeStatus(mtimeMs: number | null, nowMs: number): ScopeStatus {
  if (mtimeMs === null) return { kind: 'missing' }
  const age = nowMs - mtimeMs
  if (age < THRESHOLDS.scopeFreshMs) return { kind: 'fresh' }
  return { kind: 'stale', ageHours: Math.floor(age / 3_600_000) }
}

type MessageRow = {
  role: 'user' | 'assistant'
  toolUses: readonly { tool: string }[]
  toolResults?: readonly unknown[]
}

export function countTurnEdits(rows: readonly MessageRow[]): number {
  let edits = 0
  for (let i = rows.length - 1; i >= 0; i -= 1) {
    const row = rows[i]!
    if (row.role === 'user' && !(row.toolResults && row.toolResults.length > 0)) break
    if (row.role === 'assistant') edits += row.toolUses.filter(use => EDIT_TOOLS.has(use.tool)).length
  }
  return edits
}

type DecideInput = { turns: number; edits: number; snapshot: Snapshot; armed: Armed }
type Decision = { armed: Armed; messages: string[] }

export function decide({ turns, edits, snapshot, armed }: DecideInput): Decision {
  const messages: string[] = []
  let next = { ...armed }

  const scope = decideScope(turns, snapshot, next)
  next = scope.armed
  if (scope.message) messages.push(scope.message)

  const wiki = decideWiki(turns, edits, snapshot, next)
  next = wiki.armed
  if (wiki.message) messages.push(wiki.message)

  const cleanup = decideCleanup(turns, snapshot, next)
  next = cleanup.armed
  if (cleanup.message) messages.push(cleanup.message)

  return { armed: next, messages }
}

type Step = { armed: Armed; message?: string }

function decideScope(turns: number, snapshot: Snapshot, armed: Armed): Step {
  const status = snapshot.scope
  if (!snapshot.root || !status) return { armed }
  if (status.kind === 'fresh') return { armed: { ...armed, scope: true } }
  if (!armed.scope || turns < THRESHOLDS.scopeTurn) return { armed }
  const condition = status.kind === 'missing' ? '.scope.md is missing' : `.scope.md is ${status.ageHours}h old and may not match the current task`
  return {
    armed: { ...armed, scope: false },
    message:
      `SCOPE CHECK (turn ${turns}): ${condition}. If you are doing feature work or multi-file changes, ` +
      'answer the Three Questions before continuing: (1) Context: where are specs, plans and the wiki? ' +
      '(2) Definition of done: what declares this complete? (3) Feedback loop: how are you validating? ' +
      'Write the answers to .scope.md. If this is a quick fix or config change, ignore this reminder.',
  }
}

function decideWiki(turns: number, edits: number, snapshot: Snapshot, armed: Armed): Step {
  const wiki = snapshot.wiki
  if (!wiki) return { armed }
  let next = armed
  if (wiki.latestWriteMs > armed.wikiSeenWriteMs) {
    next = { ...next, wikiSeenWriteMs: wiki.latestWriteMs, wikiAnchorTurn: turns, wikiAnchorEdits: edits }
  }
  const written = wiki.devlogWritten && wiki.indexWritten
  const editsSince = edits - next.wikiAnchorEdits
  const turnsSince = turns - next.wikiAnchorTurn
  const due = next.wikiFired || written
    ? editsSince >= THRESHOLDS.wikiRepeatEdits || turnsSince >= THRESHOLDS.wikiRepeatTurns
    : turns >= THRESHOLDS.wikiFirstTurn
  if (!due) return { armed: next }
  const fired = { ...next, wikiFired: true, wikiAnchorTurn: turns, wikiAnchorEdits: edits }
  if (written) {
    return {
      armed: fired,
      message:
        `WIKI: ${editsSince} edits and ${turnsSince} turns since the last wiki update. If that work produced ` +
        `decisions, plans, findings or shipped changes, add a devlog entry at ${wiki.devlogPath} and update ${wiki.indexPath}.`,
    }
  }
  const missing = [!wiki.devlogWritten && 'the project devlog', !wiki.indexWritten && 'the wiki index'].filter(Boolean).join(' and ')
  return {
    armed: fired,
    message:
      `WIKI: You are ${turns} turns into this session and have not written ${missing}. ` +
      `Write a devlog entry at ${wiki.devlogPath} summarizing work so far. If you made plans, decisions, ` +
      `or ran spikes, create pages in the corresponding subdirectory. Then update ${wiki.indexPath}: ` +
      'every session must update it. Do this now, before your next task response.',
  }
}

function decideCleanup(turns: number, snapshot: Snapshot, armed: Armed): Step {
  const current = new Set(snapshot.junk)
  const kept = armed.cleanupReported.filter(path => current.has(path))
  const reported = new Set(kept)
  const fresh = snapshot.junk.filter(path => !reported.has(path))
  if (turns < THRESHOLDS.cleanupTurn || fresh.length === 0) {
    return { armed: { ...armed, cleanupReported: kept } }
  }
  const shown = fresh.slice(0, THRESHOLDS.cleanupListMax).join(', ')
  const extra = fresh.length > THRESHOLDS.cleanupListMax ? ` (and ${fresh.length - THRESHOLDS.cleanupListMax} more)` : ''
  return {
    armed: { ...armed, cleanupReported: [...kept, ...fresh] },
    message:
      `HYGIENE: untracked scratch artifacts are sitting in this repo: ${shown}${extra}. If any are leftover ` +
      'working files (temp docs, screenshots from testing, debug dumps, junk), delete them so they do not ' +
      "pollute the tree. Anything worth keeping belongs in the project's docs or notes, not as loose files " +
      'in the repo. Leave anything still in use.',
  }
}

export function modeLabels(snap: Pick<Snapshot, 'humanize' | 'ownit'>): string[] {
  const labels: string[] = []
  if (snap.humanize) labels.push(`humanize ${snap.humanize}`)
  if (snap.ownit) labels.push(`ownit ${snap.ownit}`)
  return labels
}
