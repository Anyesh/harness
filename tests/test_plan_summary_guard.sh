#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
HOOK_STAGE="$TMP_DIR/hooks"
mkdir -p "$HOOK_STAGE"
command cp "$REPO_ROOT"/configs/shared/hooks/* "$REPO_ROOT"/configs/claude-code/hooks/* "$HOOK_STAGE/"
HOOK="$HOOK_STAGE/pre-plan-summary-guard.sh"
trap 'rm -rf "$TMP_DIR"' EXIT
export HARNESS_BLOCK_LOG="$TMP_DIR/blocks.jsonl"

RC=0
ERR=""
run_hook() {
  local plan="$1" payload
  payload=$(jq -cn --arg p "$plan" '{hook_event_name:"PreToolUse",tool_name:"ExitPlanMode",tool_input:{plan:$p}}')
  RC=0
  ERR=$(bash "$HOOK" <<<"$payload" 2>&1 >/dev/null) || RC=$?
}

denied() { run_hook "$1"; [[ $RC -eq 2 ]]; }
allowed() { run_hook "$1"; [[ $RC -eq 0 && -z "$ERR" ]]; }

GOOD='# Event log

## In short

- We start recording every change to a garment so its history can be shown later.
- Nothing changes on screen yet; this only lays the groundwork.
- You need to pick whether old garments get a backfilled history.

## Context

Long detail here.'

NO_SUMMARY='# Event log

## Context

Long detail here.

## Design

More.'

SUMMARY_SECOND='# Event log

## Context

Detail.

## In short

- We record changes.
- Nothing visible yet.'

ONE_BULLET='# Event log

## In short

- We record changes.

## Context

Detail.'

SIX_BULLETS='# Event log

## In short

- a
- b
- c
- d
- e
- f

## Context

Detail.'

LONG_BULLET="# Event log

## In short

- $(printf 'word %.0s' {1..60})
- Nothing visible yet.

## Context

Detail."

LOWERCASE='# Event log

## in short

- We record changes.
- Nothing visible yet.

## Context'

NO_TITLE='## In short

* We record changes.
* Nothing visible yet.

## Context'

assert "plan opening with In short is allowed" "allowed \"\$GOOD\""
assert "plan without In short is blocked" "denied \"\$NO_SUMMARY\""
assert "block message names the guard" "denied \"\$NO_SUMMARY\" && [[ \$ERR == 'BLOCKED by pre-plan-summary-guard:'* ]]"
assert "In short after Context is blocked" "denied \"\$SUMMARY_SECOND\""
assert "a single bullet is blocked" "denied \"\$ONE_BULLET\""
assert "six bullets are blocked" "denied \"\$SIX_BULLETS\""
assert "a bullet over 200 characters is blocked" "denied \"\$LONG_BULLET\""
assert "heading match ignores case" "allowed \"\$LOWERCASE\""
assert "plan without a title and with star bullets is allowed" "allowed \"\$NO_TITLE\""
assert "empty plan is allowed" "allowed ''"
assert "blocks are logged" "[[ -s \$HARNESS_BLOCK_LOG ]] && jq -e 'select(.hook == \"pre-plan-summary-guard\")' \"\$HARNESS_BLOCK_LOG\" >/dev/null"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
