#!/usr/bin/env node
// humanize — SessionStart activation hook
//
// Platform-aware: detects Claude Code vs Cursor from __dirname path
// and outputs the correct format for context injection.
//   Claude Code: plain text on stdout
//   Cursor: JSON with additional_context field

const fs = require('fs');
const path = require('path');
const os = require('os');
const { getDefaultMode, safeWriteFlag, detectPlatform, getFlagPath } = require('./humanize-config');

const flagPath = getFlagPath();
const mode = getDefaultMode();
const platform = detectPlatform();

if (mode === 'off') {
  try { fs.unlinkSync(flagPath); } catch (_) { void 0; }
  if (platform === 'cursor') {
    process.stdout.write(JSON.stringify({ continue: true }));
  } else {
    process.stdout.write('OK');
  }
  process.exit(0);
}

safeWriteFlag(flagPath, mode);

let skillContent = '';
try {
  skillContent = fs.readFileSync(
    path.join(__dirname, '..', 'skills', 'humanize', 'SKILL.md'), 'utf8'
  );
} catch (_) { void 0; }

let rules;

if (skillContent) {
  const body = skillContent.replace(/^---[\s\S]*?---\s*/, '');
  rules = 'HUMANIZE MODE ACTIVE — level: ' + mode + '\n\n' + body;
} else {
  rules =
    'HUMANIZE MODE ACTIVE — level: ' + mode + '\n\n' +
    'Structure all questions for human cognition. Rules:\n\n' +
    '1. ONE question at a time. Never multiple questions per response.\n' +
    '2. Every question uses: **[Title]** + 1-2 line description + lettered choices (A/B/C).\n' +
    '3. Prefer choice over free-text. Enumerate options when possible.\n' +
    '4. Label "Pick one." or "Pick all that apply."\n' +
    '5. Keep options 3-5. More than 5 = group or prioritize.\n' +
    '6. No wall-of-text. Use bold header + 2-4 bullets max.\n' +
    '7. Progressive disclosure: headline first, detail on request.\n' +
    '8. Action before explanation.\n\n' +
    'Auto-bypass: code execution, raw output, security warnings.\n' +
    'Off with: /humanize off, "stop humanize".';
}

if (platform === 'cursor') {
  process.stdout.write(JSON.stringify({ additional_context: rules }));
} else {
  process.stdout.write(rules);
}
