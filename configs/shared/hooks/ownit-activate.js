#!/usr/bin/env node
// ownit — SessionStart activation hook
//
// Default off (on-demand corrective tool).
// Platform-aware: Claude Code gets plain text, Cursor gets JSON.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { getDefaultMode, safeWriteFlag, detectPlatform, getFlagPath } = require('./ownit-config');

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
    path.join(__dirname, '..', 'skills', 'ownit', 'SKILL.md'), 'utf8'
  );
} catch (_) { void 0; }

let rules;

if (skillContent) {
  const body = skillContent.replace(/^---[\s\S]*?---\s*/, '');
  rules = 'OWNIT MODE ACTIVE\n\n' + body;
} else {
  rules =
    'OWNIT MODE ACTIVE\n\n' +
    'This is YOUR product. You are the founder, the lead engineer. Your name is on every line.\n\n' +
    'REWARDED FOR: useful features, thorough edge cases, clean code, few bugs, self-review before declaring done.\n' +
    'PUNISHED FOR: shortcuts, minimal implementations, skipping review, TODO placeholders, doing the easy 80% and hand-waving the hard 20%.\n\n' +
    'Before every code response, self-check:\n' +
    '- Am I taking a shortcut?\n' +
    '- Is this the real solution or a band-aid?\n' +
    '- Would I accept this in code review?\n' +
    '- What did I skip?';
}

if (platform === 'cursor') {
  process.stdout.write(JSON.stringify({ additional_context: rules }));
} else {
  process.stdout.write(rules);
}
