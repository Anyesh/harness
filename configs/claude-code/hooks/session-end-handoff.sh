#!/usr/bin/env bash
# SessionEnd hook: when a session ends through /clear, leave a pointer to its transcript
# for the next session. The digest itself is built at SessionStart so this stays fast.

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=handoff-common.sh
source "$HOOK_DIR/handoff-common.sh"

INPUT=$(cat 2>/dev/null || true)
[[ "$(jq -r '.reason // empty' <<<"$INPUT" 2>/dev/null)" == "clear" ]] || exit 0

key="$(handoff_claude_pid)" || exit 0
pending="$(handoff_pending_dir)"
mkdir -p "$pending"

tmp="$(mktemp "$pending/.$key.XXXXXX")"
if ! jq -c --argjson ts "$(date +%s)" '{transcript_path, session_id, cwd, ts: $ts}' <<<"$INPUT" > "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  exit 0
fi
mv -f "$tmp" "$pending/$key.json"
