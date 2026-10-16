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

PLAIN="$TMP_DIR/plain"
REPO="$TMP_DIR/repo"
mkdir -p "$PLAIN" "$REPO"
git -C "$REPO" init -q -b feat-x
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

input() {
  jq -cn --arg sid "${1-$SID}" --arg dir "${2-$PLAIN}" '{
    session_id: $sid,
    workspace: (if $dir == "" then {} else { current_dir: $dir } end),
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

plain() { env -u CLAUDE_PROFILE NO_COLOR=1 XDG_STATE_HOME="$STATE" bash "$STATUSLINE"; }
line() { input "$@" | plain; }
colored() { env -u CLAUDE_PROFILE -u NO_COLOR XDG_STATE_HOME="$STATE" bash "$STATUSLINE"; }

row() { sed -n "${1}p" <<<"$out"; }

C1=" ▐▛███▜▌ "
C2="▝▜█████▛▘"
C3="  ▘▘ ▝▝  "
METRICS="Opus 5.5  │  \$4.12  │  ctx ███░░░░░ 38% 380k  │  72m"
BASE="$C1  [default] plain"$'\n'"$C2  $METRICS"$'\n'"$C3"
GREEN=$'\033[32m'
RED=$'\033[31m'

echo ""
echo "=== statusline ==="
echo ""

out=$(line)
assert "clawd spans three rows of location, metrics and an empty third row" '[[ "$out" == "$BASE" ]]'

out=$(line "$SID" "$REPO")
assert "a git folder shows its branch" '[[ "$(row 1)" == "$C1  [default] repo (feat-x)" ]]'

git -C "$REPO" checkout -q --detach
SHORT=$(git -C "$REPO" rev-parse --short HEAD)
out=$(line "$SID" "$REPO")
assert "a detached head shows its short commit" '[[ "$(row 1)" == "$C1  [default] repo ($SHORT)" ]]'
git -C "$REPO" checkout -q feat-x

out=$(input | CLAUDE_PROFILE=work NO_COLOR=1 XDG_STATE_HOME="$STATE" bash "$STATUSLINE")
assert "a profile session leads with the profile name" '[[ "$(row 1)" == "$C1  [work] plain" ]]'

out=$(line "$SID" "")
assert "no working folder keeps only the profile" '[[ "$(row 1)" == "$C1  [default]" ]]'

out=$(line)
assert "NO_COLOR prints no escape codes" '[[ "$out" != *$'"'"'\033'"'"'* ]]'

out=$(input | colored)
assert "clawd is drawn in Claude orange" '[[ "$(row 2)" == $'"'"'\033[38;5;173m▝▜█████▛▘'"'"'* ]]'
assert "context under half full draws a green bar" '[[ "$out" == *"${GREEN}███"* ]]'

out=$(input | jq -c '.rate_limits = {five_hour: {used_percentage: 85}, seven_day: {used_percentage: 20}}' | plain)
assert "quota windows sit on the third row" '[[ "$(row 3)" == "$C3  session: ████░ 85%  week: █░░░░ 20%" ]]'

out=$(input | jq -c '.context_window.used_percentage = 85' | colored)
assert "context past 80% draws a red bar" '[[ "$out" == *"${RED}██████"* ]]'

segment guard-watch "2 blocks" normal "$NOW_MS"
segment cache-guard "cache 42m" normal "$NOW_MS"
out=$(line)
assert "segments follow in fixed order" '[[ "$(row 3)" == "$C3  cache 42m  │  2 blocks" ]]'

out=$(input | jq -c '.rate_limits = {seven_day: {used_percentage: 20}}' | plain)
assert "segments follow the quota" '[[ "$(row 3)" == "$C3  week: █░░░░ 20%  │  cache 42m  │  2 blocks" ]]'

segment cache-guard 'cache cold ≈ $3.04' warn "$NOW_MS"
out=$(line)
assert "warn tone is plain under NO_COLOR" '[[ "$(row 3)" == "$C3  cache cold ≈ \$3.04  │  2 blocks" ]]'

out=$(input | colored)
assert "warn tone is drawn in yellow" '[[ "$out" == *"${YELLOW}cache cold ≈ \$3.04${RESET}"* ]]'

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
