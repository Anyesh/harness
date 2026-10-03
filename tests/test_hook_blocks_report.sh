#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT="$REPO_ROOT/scripts/hook-blocks.sh"

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
trap 'command rm -rf "$TMP_DIR"' EXIT
LOG="$TMP_DIR/blocks.jsonl"

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
old=$(date -u -d '-30 days' +%Y-%m-%dT%H:%M:%SZ)
record() { jq -cn --arg ts "$1" --arg h "$2" --arg d "$3" '{ts:$ts,hook:$h,event:"PreToolUse",agent:"claude",tool:"Bash",detail:$d,cwd:"",session:""}'; }
{
  record "$now" cost-guard 'docker logs web'
  record "$now" cost-guard 'journalctl -u web'
  record "$now" pre-bash-interactive-alias 'rm stray.json'
  record "$old" pre-bash-guard 'reboot'
  echo 'not json'
} >"$LOG"

echo "=== hook-blocks report ==="
OUT=$(bash "$REPORT" --log "$LOG" --days 7)
assert "groups blocks per hook with counts" 'grep -q "^== cost-guard: 2 blocks" <<<"$OUT" && grep -q "^== pre-bash-interactive-alias: 1 blocks" <<<"$OUT"'
assert "busiest hook comes first" '[[ $(grep -m1 "^==" <<<"$OUT") == "== cost-guard"* ]]'
assert "shows the blocked detail" 'grep -q "rm stray.json" <<<"$OUT"'
assert "drops blocks older than the window" '! grep -q "pre-bash-guard" <<<"$OUT"'
assert "skips malformed lines" '[[ -n "$OUT" ]]'

OUT=$(bash "$REPORT" --log "$LOG" --days 60)
assert "a wider window includes old blocks" 'grep -q "^== pre-bash-guard: 1 blocks" <<<"$OUT"'

OUT=$(bash "$REPORT" --log "$TMP_DIR/none.jsonl")
assert "a missing log says nothing was blocked" 'grep -qi "no blocks" <<<"$OUT"'

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
