#!/bin/bash
# Reads hook JSON from stdin; prints "cursor" or "claude".
# cursor_version is present only in Cursor payloads. hook_event_name casing
# is a secondary signal (Cursor: sessionStart, Claude: SessionStart).
# Codex payloads fall through to "claude" deliberately: Codex's hook JSON
# uses the same PascalCase event names and the same
# hookSpecificOutput.additionalContext output shape as Claude Code (verified
# against developers.openai.com/codex/hooks), so callers of this script that
# only need to pick between "cursor-shaped" and "claude-shaped" output get
# the right answer for Codex too without a dedicated branch.

INPUT=$(cat 2>/dev/null || true)

if printf '%s' "$INPUT" | jq -e '.cursor_version != null and (.cursor_version | length) > 0' >/dev/null 2>&1; then
  echo cursor
  exit 0
fi

HOOK_EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
case "$HOOK_EVENT" in
  sessionStart|sessionEnd|beforeSubmitPrompt|preToolUse|postToolUse|postToolUseFailure|\
  subagentStart|subagentStop|beforeShellExecution|afterShellExecution|\
  beforeMCPExecution|afterMCPExecution|beforeReadFile|afterFileEdit|\
  preCompact|stop|afterAgentResponse|afterAgentThought|beforeTabFileRead|afterTabFileEdit|workspaceOpen)
    echo cursor
    ;;
  *)
    echo claude
    ;;
esac
