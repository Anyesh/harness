#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUSLINE="$REPO_ROOT/configs/claude-code/scripts/statusline.sh"

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

STATE="$TMP_DIR/state"
SID="sess-1"
DIR="$STATE/harness/status/$SID"
NOW_MS=$(( $(date +%s) * 1000 ))
YELLOW=$'\033[33m'
RESET=$'\033[0m'

input() {
  jq -cn --arg sid "${1-$SID}" '{
    session_id: $sid,
    model: { display_name: "Opus 5.5" },
    cost: { total_cost_usd: 4.123, total_duration_ms: 4320000 },
    context_window: {
      context_window_size: 1000000,
      used_percentage: 38.2,
      current_usage: { input_tokens: 2000, cache_creation_input_tokens: 8000, cache_read_input_tokens: 370000 }
    }
  }'
}

segment() {
  mkdir -p "$DIR"
  jq -cn --arg text "$2" --arg tone "$3" --argjson at "$4" '{text: $text, tone: $tone, at: $at}' >"$DIR/$1.json"
}

line() { input "$@" | XDG_STATE_HOME="$STATE" bash "$STATUSLINE"; }

BASE="Opus 5.5  │  \$4.12  │  ctx ███░░░░░ 38% 380k  │  72m"

echo ""
echo "=== statusline ==="
echo ""

out=$(line)
assert "no status folder prints the base line" '[[ "$out" == "$BASE" ]]'

segment guard-watch "2 blocks" normal "$NOW_MS"
segment cache-guard "cache 42m" normal "$NOW_MS"
out=$(line)
assert "segments follow in fixed order" '[[ "$out" == "$BASE  │  cache 42m  │  2 blocks" ]]'

segment cache-guard 'cache cold ≈ $3.04' warn "$NOW_MS"
out=$(line)
assert "warn tone is drawn in yellow" '[[ "$out" == "$BASE  │  ${YELLOW}cache cold ≈ \$3.04${RESET}  │  2 blocks" ]]'

segment guard-watch "2 blocks" normal $((NOW_MS - 11 * 60 * 1000))
out=$(line)
assert "a segment older than 10 minutes is skipped" '[[ "$out" != *"2 blocks"* ]]'

: >"$DIR/cache-guard.json"
out=$(line)
assert "an emptied segment file is skipped" '[[ "$out" == "$BASE" ]]'

printf 'not json' >"$DIR/cache-guard.json"
out=$(line)
assert "a malformed segment file is skipped" '[[ "$out" == "$BASE" ]]'

segment cache-guard "cache 42m" normal "$NOW_MS"
out=$(line "../$SID")
assert "a session id with path characters reads no segments" '[[ "$out" == "$BASE" ]]'

echo ""
echo "statusline: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
