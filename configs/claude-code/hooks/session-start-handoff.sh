#!/usr/bin/env bash
# SessionStart hook: after /clear, digest the previous session and point the new one at it.
# The previous transcript comes from the pointer session-end-handoff.sh left for this claude
# process. Without a fresh pointer no digest is claimed, because a digest of the wrong session
# misleads more than no digest. No model call: the digest is built by handoff-digest.sh.
# Otherwise (startup, resume, or clear without a pointer) it names the project's handoff dir
# and newest files, so an agent asked to continue earlier work does not have to search for them.

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
DIGEST="$HOOK_DIR/../scripts/handoff-digest.sh"
# shellcheck source=handoff-common.sh
source "$HOOK_DIR/handoff-common.sh"

MAX_AGE="${HARNESS_HANDOFF_MAX_AGE:-30}"
WAIT="${HARNESS_HANDOFF_WAIT:-2}"
LIST_COUNT=3

INPUT=$(cat 2>/dev/null || true)

field() {
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null || true
}

digest_context() {
  local key pointer steps i data ended_at previous digest_path lines index_line first_block

  handoff_prune

  key="$(handoff_claude_pid)" || return 1
  pointer="$(handoff_pending_dir)/$key.json"

  # Claude Code does not document whether SessionEnd finishes before SessionStart on /clear,
  # so wait briefly for the pointer instead of assuming the order.
  steps=$(( WAIT * 20 ))
  for (( i = 0; i < steps; i++ )); do
    [[ -f "$pointer" ]] && break
    sleep 0.05
  done
  [[ -f "$pointer" ]] || return 1

  data="$(cat "$pointer" 2>/dev/null || true)"
  rm -f "$pointer"

  ended_at="$(jq -r '.ts // 0' <<<"$data" 2>/dev/null || echo 0)"
  previous="$(jq -r '.transcript_path // empty' <<<"$data" 2>/dev/null || true)"

  (( $(date +%s) - ended_at <= MAX_AGE )) || return 1
  [[ -n "$previous" && -f "$previous" ]] || return 1
  grep -q '"type":"user"' "$previous" || return 1

  digest_path="$(bash "$DIGEST" "$previous" 2>/dev/null)" || return 1
  [[ -f "$digest_path" ]] || return 1
  lines=$(wc -l < "$digest_path" | tr -d ' ')
  index_line="$(grep -n '^## Prompt index' "$digest_path" | head -n 1 | cut -d: -f1 || true)"
  first_block=$(( ${index_line:-$(( lines + 1 ))} - 1 ))

  printf '%s' "Previous session digest (built without a model call): $digest_path ($lines lines). Read lines 1-$first_block first (files touched, repo state, last plan, recent turns); the prompt index below that is for grep, read further ranges only if needed."
}

listing_context() {
  local dir paths total newest="" path

  dir="$(handoff_project_dir "$(field .cwd)")" || return 1
  paths="$(ls -t -- "$dir"/*.md 2>/dev/null || true)"
  [[ -n "$paths" ]] || return 1
  total=$(wc -l <<<"$paths" | tr -d ' ')

  while IFS= read -r path; do
    newest+="${newest:+, }${path##*/} ($(date -r "$path" '+%Y-%m-%d %H:%M'))"
  done < <(head -n "$LIST_COUNT" <<<"$paths")

  printf '%s' "Handoffs (session handovers) for this project are in $dir/, outside every profile: $total files, newest $newest. <session>.md is a digest of that session's transcript and repo state; <session>.handoff-N.md is the reasoning written when it was compacted. Read the newest relevant one when the user asks to continue earlier work."
}

source_kind="$(field .source)"
case "$source_kind" in
  startup|resume|clear) ;;
  *) exit 0 ;;
esac

context=""
if [[ "$source_kind" == "clear" ]]; then
  context="$(digest_context)" || context=""
fi
if [[ -z "$context" ]]; then
  context="$(listing_context)" || exit 0
fi

jq -nc --arg ctx "$context" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
