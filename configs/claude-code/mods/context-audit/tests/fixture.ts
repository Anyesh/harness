import type { SessionContextBreakdown } from 'claude-code'

export const BREAKDOWN = {
  categories: [],
  totalTokens: 380_000,
  maxTokens: 1_000_000,
  rawMaxTokens: 1_000_000,
  autocompactSource: 'model',
  percentage: 38,
  gridRows: [],
  model: 'claude-opus-5-5',
  isAutoCompactEnabled: true,
  apiUsage: null,
  memoryFiles: [
    { path: '/home/user/.claude/CLAUDE.md', type: 'User', tokens: 4_200 },
    { path: '/work/repo/CLAUDE.md', type: 'Project', tokens: 900 },
  ],
  mcpTools: [
    { name: 'mcp__playwright__click', serverName: 'playwright', tokens: 3_000, isLoaded: true },
    { name: 'mcp__playwright__type', serverName: 'playwright', tokens: 2_600, isLoaded: true },
    { name: 'mcp__playwright__drag', serverName: 'playwright', tokens: 400, isLoaded: false },
    { name: 'mcp__web__fetch', serverName: 'web', tokens: 800, isLoaded: true },
  ],
  agents: [
    { agentType: 'Explore', source: 'built-in', tokens: 300 },
    { agentType: 'reviewer', source: 'projectSettings', tokens: 700 },
  ],
  slashCommands: { totalCommands: 40, includedCommands: 34, tokens: 1_500 },
  skills: {
    totalSkills: 5,
    includedSkills: 5,
    tokens: 3_300,
    skillFrontmatter: [
      { name: 'impeccable', source: 'userSettings', tokens: 1_400 },
      { name: 'wiki', source: 'userSettings', tokens: 300 },
      { name: 'feature-dev', source: 'plugin', pluginName: 'feature-dev', tokens: 900 },
      { name: 'code-review', source: 'plugin', pluginName: 'feature-dev', tokens: 500 },
      { name: 'run', source: 'built-in', tokens: 200 },
    ],
  },
} as unknown as SessionContextBreakdown
