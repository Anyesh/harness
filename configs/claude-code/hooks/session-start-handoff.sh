#!/usr/bin/env bash
# SessionStart hook: after /clear, digest the previous session and point the new one at it.
# The previous transcript comes from the pointer session-end-handoff.sh left for this claude
# process. Without a fresh pointer nothing is injected, because a digest of the wrong session
# misleads more than no digest. No model call: the digest is built by handoff-digest.sh.

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
DIGEST="$HOOK_DIR/../scripts/handoff-digest.sh"
# shellcheck source=handoff-common.sh
source "$HOOK_DIR/handoff-common.sh"

MAX_AGE="${HARNESS_HANDOFF_MAX_AGE:-30}"
WAIT="${HARNESS_HANDOFF_WAIT:-2}"

INPUT=$(cat 2>/dev/null || true)

field() {
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null || true
}

[[ "$(field .source)" == "clear" ]] || exit 0

handoff_prune

key="$(handoff_claude_pid)" || exit 0
pointer="$(handoff_pending_dir)/$key.json"

# Claude Code does not document whether SessionEnd finishes before SessionStart on /clear,
# so wait briefly for the pointer instead of assuming the order.
steps=$(( WAIT * 20 ))
for (( i = 0; i < steps; i++ )); do
  [[ -f "$pointer" ]] && break
  sleep 0.05
done
[[ -f "$pointer" ]] || exit 0

data="$(cat "$pointer" 2>/dev/null || true)"
rm -f "$pointer"

ended_at="$(jq -r '.ts // 0' <<<"$data" 2>/dev/null || echo 0)"
previous="$(jq -r '.transcript_path // empty' <<<"$data" 2>/dev/null || true)"

(( $(date +%s) - ended_at <= MAX_AGE )) || exit 0
[[ -n "$previous" && -f "$previous" ]] || exit 0
grep -q '"type":"user"' "$previous" || exit 0

digest_path="$(bash "$DIGEST" "$previous" 2>/dev/null)" || exit 0
[[ -f "$digest_path" ]] || exit 0
lines=$(wc -l < "$digest_path" | tr -d ' ')
index_line="$(grep -n '^## Prompt index' "$digest_path" | head -n 1 | cut -d: -f1 || true)"
first_block=$(( ${index_line:-$(( lines + 1 ))} - 1 ))

context="Previous session digest (built without a model call): $digest_path ($lines lines). Read lines 1-$first_block first (files touched, repo state, last plan, recent turns); the prompt index below that is for grep, read further ranges only if needed."

jq -nc --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
