#!/usr/bin/env bash
# SessionStart hook: after /clear, digest the previous session and point the new one at it.
# No model call: the digest is built by handoff-digest.sh (shell and jq).

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
DIGEST="$HOOK_DIR/../scripts/handoff-digest.sh"
MAX_AGE="${HARNESS_HANDOFF_MAX_AGE:-43200}"

INPUT=$(cat 2>/dev/null || true)

field() {
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null || true
}

[[ "$(field .source)" == "clear" ]] || exit 0

current="$(field .transcript_path)"
[[ -n "$current" ]] || exit 0
dir="$(dirname "$current")"

previous="$(field '.previous_transcript_path // .old_transcript_path // .prior_transcript_path')"
if [[ -z "$previous" ]]; then
  prev_id="$(field '.previous_session_id // .old_session_id // .prior_session_id // .last_session_id')"
  [[ -n "$prev_id" ]] && previous="$dir/$prev_id.jsonl"
fi

if [[ -z "$previous" ]]; then
  now=$(date +%s)
  for f in $(ls -t "$dir"/*.jsonl 2>/dev/null); do
    [[ "$f" == "$current" ]] && continue
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    (( now - mtime <= MAX_AGE )) && previous="$f"
    break
  done
fi

[[ -n "$previous" && -f "$previous" ]] || exit 0
grep -q '"type":"user"' "$previous" || exit 0

digest_path="$(bash "$DIGEST" "$previous" 2>/dev/null)" || exit 0
[[ -f "$digest_path" ]] || exit 0
lines=$(wc -l < "$digest_path" | tr -d ' ')

context="Previous session digest (prompt index plus last turns, built without a model call): $digest_path ($lines lines). Read the last ~80 lines first; grep it or read further ranges only if needed."

jq -nc --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
