import type { ContextMcpTool, ContextSkill, SessionContextBreakdown } from 'claude-code'

const MCP_TRIM_TOKENS = 5_000
const SKILL_TRIM_TOKENS = 1_000
const MEMORY_TRIM_TOKENS = 3_000
const MAX_CANDIDATES = 5

export type McpServer = { name: string; loaded: number; deferred: number; tools: number }
export type SkillGroup = { name: string; tokens: number; count: number }
export type Candidate = { label: string; tokens: number; share: number }

export function formatTokens(tokens: number): string {
  if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`
  if (tokens >= 100_000) return `${Math.round(tokens / 1000)}k`
  if (tokens >= 1000) return `${(tokens / 1000).toFixed(1)}k`
  return String(tokens)
}

function plural(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? '' : 's'}`
}

function formatShare(share: number): string {
  return `${(share * 100).toFixed(1)}%`
}

export function mcpServers(tools: readonly ContextMcpTool[]): McpServer[] {
  const servers = new Map<string, McpServer>()
  for (const tool of tools) {
    const server = servers.get(tool.serverName) ?? { name: tool.serverName, loaded: 0, deferred: 0, tools: 0 }
    if (tool.isLoaded) server.loaded += tool.tokens
    else server.deferred += tool.tokens
    server.tools += 1
    servers.set(tool.serverName, server)
  }
  return [...servers.values()].sort((a, b) => b.loaded + b.deferred - (a.loaded + a.deferred))
}

export function skillGroups(skills: readonly ContextSkill[]): SkillGroup[] {
  const groups = new Map<string, SkillGroup>()
  for (const skill of skills) {
    const name = skill.pluginName ? `plugin ${skill.pluginName}` : skill.source
    const group = groups.get(name) ?? { name, tokens: 0, count: 0 }
    group.tokens += skill.tokens
    group.count += 1
    groups.set(name, group)
  }
  return [...groups.values()].sort((a, b) => b.tokens - a.tokens)
}

// A server is judged by its loaded tokens, because a deferred MCP tool costs only its name until loaded.
export function trimCandidates(breakdown: SessionContextBreakdown): Candidate[] {
  const window = breakdown.maxTokens || 1
  const candidates = [
    ...mcpServers(breakdown.mcpTools)
      .filter(s => s.loaded > MCP_TRIM_TOKENS)
      .map(s => ({ label: `MCP server ${s.name}`, tokens: s.loaded })),
    ...(breakdown.skills?.skillFrontmatter ?? [])
      .filter(s => s.tokens > SKILL_TRIM_TOKENS)
      .map(s => ({ label: `skill ${s.name}`, tokens: s.tokens })),
    ...breakdown.memoryFiles
      .filter(m => m.tokens > MEMORY_TRIM_TOKENS)
      .map(m => ({ label: `memory ${m.path}`, tokens: m.tokens })),
  ]
  return candidates
    .sort((a, b) => b.tokens - a.tokens)
    .slice(0, MAX_CANDIDATES)
    .map(c => ({ ...c, share: c.tokens / window }))
}

function section(title: string, rows: string[]): string[] {
  return rows.length === 0 ? [] : ['', title, ...rows]
}

export function auditText(breakdown: SessionContextBreakdown): string {
  const servers = mcpServers(breakdown.mcpTools)
  const skills = breakdown.skills
  const lines = [
    `Context audit: ${formatTokens(breakdown.totalTokens)} of ${formatTokens(breakdown.maxTokens)} (${Math.round(breakdown.percentage)}%)`,
    ...section(
      'MCP servers',
      servers.map(s => `  ${s.name}  ${formatTokens(s.loaded)} loaded  ${formatTokens(s.deferred)} deferred  ${plural(s.tools, 'tool')}`),
    ),
    ...section(
      skills ? `Skills: ${skills.includedSkills} of ${skills.totalSkills} listed, ${formatTokens(skills.tokens)}` : 'Skills',
      skillGroups(skills?.skillFrontmatter ?? []).map(
        g => `  ${g.name}  ${formatTokens(g.tokens)}  ${plural(g.count, 'skill')}`,
      ),
    ),
    ...section(
      'Memory files',
      [...breakdown.memoryFiles].sort((a, b) => b.tokens - a.tokens).map(m => `  ${formatTokens(m.tokens)}  ${m.path}`),
    ),
    ...section(
      'Agents',
      [...breakdown.agents].sort((a, b) => b.tokens - a.tokens).map(a => `  ${formatTokens(a.tokens)}  ${a.agentType} (${a.source})`),
    ),
  ]
  const commands = breakdown.slashCommands
  if (commands) {
    lines.push('', `Slash commands: ${commands.includedCommands} of ${commands.totalCommands} listed, ${formatTokens(commands.tokens)}`)
  }
  const candidates = trimCandidates(breakdown)
  lines.push('', 'Trim candidates')
  if (candidates.length === 0) lines.push('  Nothing over the trim thresholds.')
  for (const c of candidates) lines.push(`  ${c.label}  ${formatTokens(c.tokens)}  ${formatShare(c.share)} of the window`)
  return lines.join('\n')
}
