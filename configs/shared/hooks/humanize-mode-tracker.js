#!/usr/bin/env node
// humanize — per-turn hook to track mode and reinforce behavior
//
// Platform-aware:
//   Claude Code (UserPromptSubmit): reads stdin JSON, emits hookSpecificOutput
//   Cursor (beforeSubmitPrompt): reads stdin JSON, manages flag file only
//     (Cursor beforeSubmitPrompt does not support additionalContext injection;
//      reinforcement happens via postToolUse or sessionStart persistence)

const fs = require('fs');
const path = require('path');
const os = require('os');
const { getDefaultMode, safeWriteFlag, readFlag, VALID_MODES, detectPlatform, getFlagPath, getStateDir } = require('./humanize-config');

// The reminder persists in conversation history every time it is emitted, so
// per-prompt emission compounds cost across long sessions. Every 3rd prompt
// keeps the mode alive (and survives compaction) at a third of the cost.
const REMIND_EVERY = 3;

function shouldRemind(sessionId) {
  if (!sessionId) return true;
  try {
    const dir = getStateDir();
    fs.mkdirSync(dir, { recursive: true });
    const marker = path.join(dir, sessionId + '.count');
    let count = 0;
    try {
      const raw = fs.readFileSync(marker, 'utf8').trim();
      if (/^\d+$/.test(raw)) count = parseInt(raw, 10);
    } catch (_) { void 0; }
    count += 1;
    fs.writeFileSync(marker, String(count));
    return count % REMIND_EVERY === 1;
  } catch (_) {
    return true;
  }
}

const flagPath = getFlagPath();
const platform = detectPlatform();

let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  try {
    const data = JSON.parse(input);
    const prompt = (data.prompt || '').trim().toLowerCase();

    if (/\b(activate|enable|turn on|start)\b.*\bhumanize\b/i.test(prompt) ||
        /\bhumanize\b.*\b(mode|activate|enable|turn on|start)\b/i.test(prompt)) {
      if (!/\b(stop|disable|turn off|deactivate)\b/i.test(prompt)) {
        const mode = getDefaultMode();
        if (mode !== 'off') {
          safeWriteFlag(flagPath, mode);
        }
      }
    }

    if (prompt.startsWith('/humanize')) {
      const parts = prompt.split(/\s+/);
      const arg = parts[1] || '';

      let mode = null;

      if (!arg) {
        mode = getDefaultMode();
      } else if (arg === 'off' || arg === 'stop' || arg === 'disable') {
        mode = 'off';
      } else if (arg === 'on') {
        mode = 'on';
      } else if (arg === 'strict') {
        mode = 'strict';
      }

      if (mode && mode !== 'off') {
        safeWriteFlag(flagPath, mode);
      } else if (mode === 'off') {
        try { fs.unlinkSync(flagPath); } catch (_) { void 0; }
      }
    }

    if (/\b(stop|disable|deactivate|turn off)\b.*\bhumanize\b/i.test(prompt) ||
        /\bhumanize\b.*\b(stop|disable|deactivate|turn off)\b/i.test(prompt)) {
      try { fs.unlinkSync(flagPath); } catch (_) { void 0; }
    }

    const sessionId = data.conversation_id || data.session_id || '';
    const activeMode = readFlag(flagPath);
    if (activeMode && shouldRemind(sessionId)) {
      const strictExtra = activeMode === 'strict'
        ? ' STRICT: a request tacked on after the question ("also tell me X") counts as a second question.'
        : '';

      const reminder = "HUMANIZE MODE ACTIVE (" + activeMode + "). " +
        "ONE question per response. " +
        "Ask through the structured question tool with 2-4 options, recommended first; " +
        "a lettered list (A/B/C) only where no such tool exists. " +
        "Prefer choice over free-text. Label single/multi-select. " +
        "No wall-of-text. Bold header + at most 4 bullets. " +
        "Headline first: what you did, found or recommend; for a diagnosis or proposed change, finding then evidence then fix. " +
        "The global Response Format bypasses apply to these output rules only; the question rules (one question, through the structured tool) hold everywhere." + strictExtra;

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
