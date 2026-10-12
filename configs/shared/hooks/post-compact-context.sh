#!/usr/bin/env bash
# Re-injects the active .scope.md after a context compaction.
#
# Claude Code and Codex: SessionStart with source "compact" reaches the model
# for manual and auto compaction alike. PreCompact output cannot, because
# Claude Code sends it to the debug log and Codex ignores its stdout.
#
# Cursor: preCompact is observational and nothing fires after a summary, so
# preCompact leaves a per-conversation mark and the next postToolUse delivers
# the note through additional_context, the only Cursor channel into the agent.
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"

INPUT=$(cat 2>/dev/null || true)
AGENT=$("$HOOK_DIR/detect-agent.sh" <<< "$INPUT")
EVENT=$(jq -r '.hook_event_name // empty' <<< "$INPUT" 2>/dev/null || true)

note_for_workspace() {
  local root
  root="$(harness_repo_root "$INPUT")"
  harness_is_tooling_dir "$root" && return 0
  bash "$HOOK_DIR/compact-note.sh" "$root"
}

if [[ "$AGENT" != "cursor" ]]; then
  [[ "$EVENT" == "SessionStart" ]] || exit 0
  [[ "$(jq -r '.source // empty' <<< "$INPUT" 2>/dev/null || true)" == "compact" ]] || exit 0
  NOTE=$(note_for_workspace)
  [[ -n "$NOTE" ]] || exit 0
  jq -n --arg ctx "$NOTE" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
  exit 0
fi

CONVERSATION_ID=$(jq -r '.conversation_id // empty' <<< "$INPUT" 2>/dev/null || true)
# Ids become file names, so anything beyond a plain token is refused to keep
# writes inside the state dir.
if [[ ! "$CONVERSATION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo '{}'
  exit 0
fi

STATE_DIR="${COMPACT_SCOPE_STATE_DIR:-$HOME/.cursor/state/compact-scope}"
MARK="$STATE_DIR/$CONVERSATION_ID"
MAX_MARK_AGE_MIN=1440

case "$EVENT" in
  preCompact)
    mkdir -p "$STATE_DIR"
    : > "$MARK"
    find "$STATE_DIR" -type f -mmin "+$MAX_MARK_AGE_MIN" -delete 2>/dev/null || true
    echo '{}'
    ;;
  postToolUse)
    NOTE=""
    if [[ -e "$MARK" ]]; then
      FRESH=$(find "$MARK" -mmin "-$MAX_MARK_AGE_MIN" 2>/dev/null || true)
      rm -f "$MARK"
      [[ -z "$FRESH" ]] || NOTE=$(note_for_workspace)
    fi
    if [[ -n "$NOTE" ]]; then
      jq -n --arg ctx "$NOTE" '{additional_context: $ctx}'
    else
      echo '{}'
    fi
    ;;
  *)
    echo '{}'
    ;;
esac
