import { isJunk, isToolingDir, projectSlug, scopeStatus } from './rules'
import type { Snapshot, WikiStatus } from '../types'

export type ProbeIO = {
  exists: (path: string) => Promise<boolean>
  stat: (path: string) => Promise<{ kind: 'file' | 'dir' | 'other'; mtimeMs: number }>
  read: (path: string) => Promise<string>
  run: (argv: readonly string[], cwd?: string) => Promise<{ exitCode: number; stdout: string }>
  vars: () => Promise<{ home?: string; configDir?: string; unattended?: string }>
  cwd: () => Promise<string>
  now: () => Promise<number>
}

async function mtime(io: ProbeIO, path: string): Promise<number | null> {
  if (!(await io.exists(path))) return null
  const stat = await io.stat(path)
  return stat.kind === 'file' ? stat.mtimeMs : null
}

async function flag(io: ProbeIO, path: string): Promise<string | null> {
  if ((await mtime(io, path)) === null) return null
  const text = (await io.read(path)).trim().toLowerCase()
  return text.length > 0 && text.length <= 64 ? text : null
}

async function git(io: ProbeIO, args: string[], cwd?: string): Promise<string | null> {
  const result = await io.run(['git', ...args], cwd)
  return result.exitCode === 0 ? result.stdout : null
}

// The harness hooks own the wiki slug and vault routing rules; a third output
// line means some page other than the devlog or index changed since start.
const WIKI_LOCATE = `
. "$1/load-harness-env.sh" && . "$1/harness-project.sh" || exit 1
load_wiki_vault
slug=$(harness_wiki_slug "$2")
vault=$(harness_wiki_vault_for "$slug")
printf '%s\\n%s\\n' "$slug" "$vault"
[ -n "$vault" ] && find "$vault/wiki/projects/$slug" -name '*.md' ! -name devlog.md ! -name index.md -newermt "@$3" -print -quit 2>/dev/null
exit 0
`

async function wikiStatus(io: ProbeIO, hooksDir: string, root: string, startedAt: number): Promise<{ slug: string; wiki: WikiStatus | null }> {
  const located = await io.run(['bash', '-c', WIKI_LOCATE, 'wiki-locate', hooksDir, root, String(Math.floor(startedAt / 1000))])
  const [slug = '', vault = '', changed = ''] = located.exitCode === 0 ? located.stdout.split('\n') : []
  if (!vault || !slug) return { slug: slug || projectSlug(root), wiki: null }
  const devlogPath = `${vault}/wiki/projects/${slug}/devlog.md`
  const indexPath = `${vault}/wiki/projects/${slug}/index.md`
  const [devlog, index] = await Promise.all([mtime(io, devlogPath), mtime(io, indexPath)])
  const since = (m: number | null) => (m !== null && m >= startedAt ? m : 0)
  return {
    slug,
    wiki: {
      devlogPath,
      indexPath,
      devlogWritten: since(devlog) > 0,
      indexWritten: since(index) > 0,
      pagesChanged: changed.length > 0,
      latestWriteMs: Math.max(since(devlog), since(index)),
    },
  }
}

export async function probe(io: ProbeIO, startedAt: number): Promise<Snapshot> {
  const vars = await io.vars()
  const home = vars.home ?? ''
  const configDir = vars.configDir || `${home}/.claude`
  const top = await git(io, ['rev-parse', '--show-toplevel'])
  const isGit = top !== null
  const cwd = isGit ? top.trim() : await io.cwd()
  const root = cwd && !isToolingDir(cwd, home) ? cwd : null
  const now = await io.now()

  const [scopeMtime, located, untracked, humanize, ownit] = await Promise.all([
    root ? mtime(io, `${root}/.scope.md`) : Promise.resolve(null),
    root ? wikiStatus(io, `${configDir}/hooks`, root, startedAt) : Promise.resolve({ slug: '', wiki: null }),
    root && isGit ? git(io, ['ls-files', '--others', '--exclude-standard'], root) : Promise.resolve(null),
    flag(io, `${configDir}/.humanize-active`),
    flag(io, `${configDir}/.ownit-active`),
  ])

  return {
    root,
    isGit,
    slug: located.slug,
    scope: root ? scopeStatus(scopeMtime, now) : null,
    wiki: located.wiki,
    junk: (untracked ?? '').split('\n').filter(path => path.length > 0 && isJunk(path)),
    humanize,
    ownit,
    unattended: vars.unattended === '1',
  }
}
