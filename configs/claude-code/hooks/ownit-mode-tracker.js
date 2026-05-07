#!/usr/bin/env node
// ownit — per-turn hook to track mode and reinforce ownership mindset
//
// Platform-aware:
//   Claude Code (UserPromptSubmit): emits hookSpecificOutput with additionalContext
//   Cursor (beforeSubmitPrompt): manages flag file, no per-turn context injection

const fs = require('fs');
const path = require('path');
const os = require('os');
const { getDefaultMode, safeWriteFlag, readFlag, detectPlatform, getFlagPath } = require('./ownit-config');

const flagPath = getFlagPath();
const platform = detectPlatform();

let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input);
    const prompt = (data.prompt || '').trim().toLowerCase();

    if (/\b(activate|enable|turn on|start)\b.*\bownit\b/i.test(prompt) ||
        /\bownit\b.*\b(activate|enable|turn on|start)\b/i.test(prompt) ||
        /\bown it\b/i.test(prompt)) {
      if (!/\b(stop|disable|turn off|deactivate|stand down)\b/i.test(prompt)) {
        safeWriteFlag(flagPath, 'on');
      }
    }

    if (prompt.startsWith('/ownit')) {
      const parts = prompt.split(/\s+/);
      const arg = parts[1] || '';

      if (!arg || arg === 'on') {
        safeWriteFlag(flagPath, 'on');
      } else if (arg === 'off' || arg === 'stop' || arg === 'disable') {
        try { fs.unlinkSync(flagPath); } catch (_) { void 0; }
      }
    }

    if (/\b(stand down)\b/i.test(prompt) ||
        /\b(stop|disable|deactivate|turn off)\b.*\bownit\b/i.test(prompt) ||
        /\bownit\b.*\b(stop|disable|deactivate|turn off)\b/i.test(prompt)) {
      try { fs.unlinkSync(flagPath); } catch (_) { void 0; }
    }

    const activeMode = readFlag(flagPath);
    if (activeMode) {
      const reminder = "OWNIT MODE ACTIVE. " +
        "This is YOUR product. You are the founder. Your name is on every line of code. " +
        "REWARDED: thoroughness, useful features, edge case handling, self-review, production-quality code. " +
        "PUNISHED: shortcuts, minimal implementations, sloppy work, skipping review, TODO placeholders, band-aids. " +
        "Before responding with code: (1) Am I taking a shortcut? (2) Is this the real solution? (3) Would I accept this in code review? (4) What did I skip? " +
        "If any answer is uncomfortable, fix it before responding.";

      if (platform === 'cursor') {
        process.stdout.write(JSON.stringify({ continue: true }));
      } else {
        process.stdout.write(JSON.stringify({
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: reminder
          }
        }));
      }
    }
  } catch (_) {
    // to prevent hook errors from blocking user input
    void 0;
  }
});
