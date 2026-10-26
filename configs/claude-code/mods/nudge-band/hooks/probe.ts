import { isJunk, isToolingDir, projectSlug, scopeStatus } from './rules'
import type { Snapshot, WikiStatus } from '../types'

export type ProbeIO = {
  exists: (path: string) => Promise<boolean>
  stat: (path: string) => Promise<{ kind: 'file' | 'dir' | 'other'; mtimeMs: number }>
  read: (path: string) => Promise<string>
  run: (argv: readonly string[], cwd?: string) => Promise<{ exitCode: number; stdout: string }>
  vars: () => Promise<{ home?: string; configDir?: string; wikiVault?: string; unattended?: string }>
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

async function wikiStatus(io: ProbeIO, vault: string | undefined, slug: string, startedAt: number): Promise<WikiStatus | null> {
  if (!vault || !slug) return null
  const devlogPath = `${vault}/wiki/projects/${slug}/devlog.md`
  const indexPath = `${vault}/wiki/index.md`
  const [devlog, index] = await Promise.all([mtime(io, devlogPath), mtime(io, indexPath)])
  const since = (m: number | null) => (m !== null && m >= startedAt ? m : 0)
  return {
    devlogPath,
    indexPath,
    devlogWritten: since(devlog) > 0,
    indexWritten: since(index) > 0,
    latestWriteMs: Math.max(since(devlog), since(index)),
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
  const slug = root ? projectSlug(root) : ''
  const now = await io.now()

  const [scopeMtime, wiki, untracked, humanize, ownit] = await Promise.all([
    root ? mtime(io, `${root}/.scope.md`) : Promise.resolve(null),
    root ? wikiStatus(io, vars.wikiVault, slug, startedAt) : Promise.resolve(null),
    root && isGit ? git(io, ['ls-files', '--others', '--exclude-standard'], root) : Promise.resolve(null),
    flag(io, `${configDir}/.humanize-active`),
    flag(io, `${configDir}/.ownit-active`),
  ])

  return {
    root,
    isGit,
    slug,
    scope: root ? scopeStatus(scopeMtime, now) : null,
    wiki,
    junk: (untracked ?? '').split('\n').filter(path => path.length > 0 && isJunk(path)),
    humanize,
    ownit,
    unattended: vars.unattended === '1',
  }
}
