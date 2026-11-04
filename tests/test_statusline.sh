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

unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH

TMP_DIR=$(mktemp -d)
SLOW_DIR=$(mktemp -d)
trap 'kill "$(cat "$SLOW_DIR/pid" 2>/dev/null)" 2>/dev/null || true; command rm -rf "$TMP_DIR" "$SLOW_DIR" || true' EXIT

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
METRICS="Opus 5.5  │  \$4.12  │  ⛁ ███░░░░░ 38% 380k  │  ◉ 97%  │  up 1h12m"
BASE="$C1  [default] plain"$'\n'"$C2  $METRICS"$'\n'"$C3"
GREEN=$'\033[32m'
RED=$'\033[31m'
NOW_S=$(date +%s)

no_segments() { command rm -rf "$DIR"; }
no_usage() { jq -c '.context_window.current_usage = {input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0}'; }
low_hit() { jq -c '.context_window.current_usage = {input_tokens: 200000, cache_creation_input_tokens: 80000, cache_read_input_tokens: 100000}'; }

echo ""
echo "=== statusline ==="
echo ""

out=$(line)
assert "clawd spans three rows of location, session figures and an empty third row" '[[ "$out" == "$BASE" ]]'

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

out=$(input | jq -c '.context_window.used_percentage = 85' | colored)
assert "context past 80% draws a red bar" '[[ "$out" == *"${RED}██████"* ]]'

out=$(input | jq -c '.cost.total_duration_ms = 2520000' | plain)
assert "a session under an hour shows its uptime in minutes" '[[ "$(row 2)" == *"│  up 42m" ]]'

out=$(input | jq -c '.cost.total_duration_ms = 4320000.7' | plain)
assert "a fractional duration still shows the uptime" '[[ "$(row 2)" == *"│  up 1h12m" ]]'

out=$(input | jq -c --argjson r $((NOW_S + 7830)) '.rate_limits = {five_hour: {used_percentage: 85, resets_at: $r}, seven_day: {used_percentage: 20}}' | plain)
assert "the quota row shows the 5h window with its reset, then the 7d window" '[[ "$(row 3)" == "$C3  5h ████░ 85% ↻2h10m  │  7d █░░░░ 20%" ]]'

out=$(input | jq -c --argjson r $((NOW_S + 2550)) '.rate_limits = {five_hour: {used_percentage: 85, resets_at: $r}}' | plain)
assert "a reset under an hour away shows minutes" '[[ "$(row 3)" == "$C3  5h ████░ 85% ↻42m" ]]'

out=$(input | jq -c --argjson r $((NOW_S - 60)) '.rate_limits = {five_hour: {used_percentage: 85, resets_at: $r}}' | plain)
assert "a reset already past shows no countdown" '[[ "$(row 3)" == "$C3  5h ████░ 85%" ]]'

segment cache-guard "◷ 42m left" normal "$NOW_MS"
out=$(line)
assert "the cache slot shows the timer then the hit rate" '[[ "$(row 2)" == "$C2  Opus 5.5  │  \$4.12  │  ⛁ ███░░░░░ 38% 380k  │  ◷ 42m left ◉ 97%  │  up 1h12m" ]]'

out=$(input | no_usage | plain)
assert "no usage yet leaves the timer alone in the cache slot" '[[ "$(row 2)" == *"│  ◷ 42m left  │  up 1h12m" ]]'

no_segments
out=$(input | no_usage | plain)
assert "no timer and no usage drop the cache slot" '[[ "$(row 2)" == *" 380k  │  up 1h12m" ]]'

out=$(input | low_hit | colored)
assert "a hit rate under 80% is drawn in red" '[[ "$out" == *"${RED}◉ 26%${RESET}"* ]]'

out=$(input | colored)
assert "a hit rate of 80% or more is not red" '[[ "$out" == *"◉ 97%"* && "$out" != *"${RED}◉"* ]]'

segment cache-guard '◷ cold ≈ $3.04' warn "$NOW_MS"
segment cache-guard-agents "◈ 2 agents · 1 cold" warn "$NOW_MS"
segment guard-watch "⊘ 2 blocks" normal "$NOW_MS"
out=$(line)
assert "a cold timer is plain under NO_COLOR" '[[ "$(row 2)" == *"│  ◷ cold ≈ \$3.04 ◉ 97%  │"* ]]'
assert "agents then blocks fill the third row" '[[ "$(row 3)" == "$C3  ◈ 2 agents · 1 cold  │  ⊘ 2 blocks" ]]'

out=$(input | jq -c '.rate_limits = {seven_day: {used_percentage: 20}}' | plain)
assert "agents and blocks follow the quota" '[[ "$(row 3)" == "$C3  7d █░░░░ 20%  │  ◈ 2 agents · 1 cold  │  ⊘ 2 blocks" ]]'

out=$(input | colored)
assert "a cold timer is drawn in yellow" '[[ "$(row 2)" == *"${YELLOW}◷ cold ≈ \$3.04${RESET}"* ]]'
assert "a warn segment on the third row is drawn in yellow" '[[ "$(row 3)" == *"${YELLOW}◈ 2 agents · 1 cold${RESET}"* ]]'

segment guard-watch "⊘ 2 blocks" normal $((NOW_MS - 11 * 60 * 1000))
segment cache-guard-agents "◈ 2 agents" normal $((NOW_MS - 11 * 60 * 1000))
out=$(line)
assert "segments older than 10 minutes drop from the third row" '[[ "$(row 3)" == "$C3" ]]'

segment cache-guard "◷ 42m left" normal $((NOW_MS - 11 * 60 * 1000))
out=$(line)
assert "a stale timer drops while the hit rate stays" '[[ "$out" == "$BASE" ]]'

: >"$DIR/cache-guard.json"
out=$(line)
assert "an emptied segment file is skipped" '[[ "$out" == "$BASE" ]]'

printf 'not json' >"$DIR/cache-guard.json"
printf 'not json' >"$DIR/cache-guard-agents.json"
out=$(line)
assert "a malformed segment file is skipped" '[[ "$out" == "$BASE" ]]'

segment cache-guard "◷ 42m left" normal "$NOW_MS"
segment cache-guard-agents "◈ 2 agents" normal "$NOW_MS"
out=$(line "../$SID")
assert "a session id with path characters reads no segments" '[[ "$out" == "$BASE" ]]'
no_segments

USAGE="$STATE/harness/usage/sessions"
limits() { jq -c '.rate_limits = {five_hour: {used_percentage: 38.2, resets_at: 1738425600.5}, seven_day: {used_percentage: 61, resets_at: 1738900000}}'; }
usage() { jq -cS . "$USAGE/$1.json" 2>/dev/null; }
expect_usage() {
  jq -cnS --arg p "$1" --argjson s "$2" --argjson w "$3" \
    '{profile: $p, context_tokens: 380000, context_window: 1000000, session: $s, week: $w}'
}
FULL_S='{"pct":38,"resets":1738425600}'
FULL_W='{"pct":61,"resets":1738900000}'
NULLS='{"pct":null,"resets":null}'

input u-ero | limits | CLAUDE_PROFILE=ero NO_COLOR=1 XDG_STATE_HOME="$STATE" bash "$STATUSLINE" >/dev/null
assert "a profile session records its usage with floored figures" '[[ "$(usage u-ero)" == "$(expect_usage ero "$FULL_S" "$FULL_W")" ]]'

input u-def | limits | plain >/dev/null
assert "a plain session records its usage under the default profile" '[[ "$(usage u-def)" == "$(expect_usage default "$FULL_S" "$FULL_W")" ]]'

input u-week | jq -c '.rate_limits = {seven_day: {used_percentage: 61, resets_at: 1738900000}}' | plain >/dev/null
assert "a missing five hour window records null figures" '[[ "$(usage u-week)" == "$(expect_usage default "$NULLS" "$FULL_W")" ]]'

input u-none | plain >/dev/null
assert "no rate limits still records profile and context" '[[ "$(usage u-none)" == "$(expect_usage default "$NULLS" "$NULLS")" ]]'

touch -t 202001010000 "$USAGE/u-def.json" "$TMP_DIR/ref"
input u-def | limits | plain >/dev/null
assert "unchanged usage leaves the file mtime alone" '! [[ "$USAGE/u-def.json" -nt "$TMP_DIR/ref" ]]'

input "" | limits | plain >/dev/null
assert "no session id records nothing" '[[ ! -e "$USAGE/.json" ]]'

OLD_STATUS="$STATE/harness/status/old-sid/cache-guard.json"
mkdir -p "$(dirname "$OLD_STATUS")"
: >"$OLD_STATUS"
: >"$USAGE/old.json"
: >"$USAGE/week.json"
: >"$USAGE/old.txt"
touch -d '9 days ago' "$USAGE/old.json" "$USAGE/old.txt" "$OLD_STATUS"
touch -d '7 days ago' "$USAGE/week.json"
input u-prune | plain >/dev/null
assert "creating a usage file prunes session files older than 8 days" '[[ ! -e "$USAGE/old.json" ]]'
assert "pruning keeps a 7 day old session file" '[[ -e "$USAGE/week.json" ]]'
assert "pruning keeps a non-json file" '[[ -e "$USAGE/old.txt" ]]'
assert "pruning leaves status files alone" '[[ -e "$OLD_STATUS" ]]'

: >"$USAGE/old.json"
touch -d '9 days ago' "$USAGE/old.json"
input u-prune | limits | plain >/dev/null
assert "rewriting a usage file prunes nothing" '[[ -e "$USAGE/old.json" && "$(usage u-prune)" == "$(expect_usage default "$FULL_S" "$FULL_W")" ]]'

out=$(input u-x | env -u CLAUDE_PROFILE NO_COLOR=1 XDG_STATE_HOME=/dev/null/nope bash "$STATUSLINE" 2>&1)
assert "an unwritable state dir still prints the status line and no errors" '[[ "$out" == "$BASE" ]]'

echo ""
echo "=== herdr sidebar ==="
echo ""

FAKE_HERDR="$TMP_DIR/fake-herdr"
cat >"$FAKE_HERDR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
exit "${HERDR_RC:-0}"
EOF
SLOW_HERDR="$TMP_DIR/slow-herdr"
cat >"$SLOW_HERDR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_LOG"
if [ ! -e "$SLOW_DIR/marker" ]; then
  : >"$SLOW_DIR/marker"
  echo $$ >"$SLOW_DIR/pid"
  exec sleep 5
fi
EOF
FAKE_PATH="$TMP_DIR/fake-path"
mkdir -p "$FAKE_PATH"
chmod +x "$FAKE_HERDR" "$SLOW_HERDR"
ln -s "$FAKE_HERDR" "$FAKE_PATH/herdr"

SET="pane report-metadata p-1 --source harness-statusline --ttl-ms 60000"
CLEAR="pane report-metadata p-1 --source harness-statusline"

in_pane() {
  local log=$1 profile=$2
  shift 2
  : >"$log"
  env CLAUDE_PROFILE="$profile" NO_COLOR=1 XDG_STATE_HOME="$STATE" HERDR_PANE_ID=p-1 \
    HERDR_BIN_PATH="$FAKE_HERDR" HERDR_LOG="$log" "$@" bash "$STATUSLINE"
}

wait_calls() {
  local n=0
  while (($(wc -l <"$1") < 2 && n < 20)); do
    sleep 0.1
    n=$((n + 1))
  done
}

call() { sed -n "${2}p" "$1"; }

LOG="$TMP_DIR/default.log"
: >"$LOG"
out=$(input side | env -u CLAUDE_PROFILE NO_COLOR=1 XDG_STATE_HOME="$STATE" HERDR_PANE_ID=p-1 \
  HERDR_BIN_PATH="$FAKE_HERDR" HERDR_LOG="$LOG" bash "$STATUSLINE")
wait_calls "$LOG"
assert "publishing to the sidebar leaves the status line unchanged" '[[ "$out" == "$BASE" ]]'
assert "a pane gets its profile, context and cache hit" \
  '[[ "$(call "$LOG" 1)" == "$SET --token claude_profile=default --token claude_ctx=⛁ 380k --token claude_cache=◉ 97%" ]]'
assert "a healthy cache clears the low cache token" '[[ "$(call "$LOG" 2)" == "$CLEAR --clear-token claude_cache_low" ]]'

LOG="$TMP_DIR/low.log"
input side | jq -c '.context_window.current_usage = {input_tokens: 200000, cache_creation_input_tokens: 80000, cache_read_input_tokens: 100000}' |
  in_pane "$LOG" default >/dev/null
wait_calls "$LOG"
assert "a hit rate under 80% goes to the low cache token" \
  '[[ "$(call "$LOG" 1)" == "$SET --token claude_profile=default --token claude_ctx=⛁ 380k --token claude_cache_low=◉ 26%" ]]'
assert "a low hit rate clears the normal cache token" '[[ "$(call "$LOG" 2)" == "$CLEAR --clear-token claude_cache" ]]'

LOG="$TMP_DIR/zero.log"
input side | jq -c '.context_window.current_usage = {input_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0}' |
  in_pane "$LOG" default >/dev/null
wait_calls "$LOG"
assert "no usage yet publishes no cache token" \
  '[[ "$(call "$LOG" 1)" == "$SET --token claude_profile=default --token claude_ctx=⛁ 380k" ]]'
assert "no usage yet clears both cache tokens" \
  '[[ "$(call "$LOG" 2)" == "$CLEAR --clear-token claude_cache --clear-token claude_cache_low" ]]'

LOG="$TMP_DIR/ero.log"
input side | in_pane "$LOG" ero >/dev/null
wait_calls "$LOG"
assert "a profile session shows its profile" '[[ "$(call "$LOG" 1)" == *"--token claude_profile=ero "* ]]'

LOG="$TMP_DIR/stale.log"
: >"$LOG"
input side | env -u CLAUDE_PROFILE NO_COLOR=1 XDG_STATE_HOME="$STATE" HERDR_PANE_ID=p-1 \
  HERDR_BIN_PATH="$TMP_DIR/gone" HERDR_LOG="$LOG" PATH="$FAKE_PATH:$PATH" bash "$STATUSLINE" >/dev/null
wait_calls "$LOG"
assert "a stale HERDR_BIN_PATH falls back to herdr on PATH" '[[ "$(call "$LOG" 1)" == "$SET "* ]]'

LOG="$TMP_DIR/fail.log"
out=$(input side | in_pane "$LOG" default HERDR_RC=1)
wait_calls "$LOG"
assert "a failing herdr leaves the status line unchanged" '[[ "$out" == "$BASE" ]]'

LOG="$SLOW_DIR/slow.log"
: >"$LOG"
start=$(date +%s)
out=$(input side | env -u CLAUDE_PROFILE NO_COLOR=1 XDG_STATE_HOME="$STATE" HERDR_PANE_ID=p-1 \
  HERDR_BIN_PATH="$SLOW_HERDR" HERDR_LOG="$LOG" SLOW_DIR="$SLOW_DIR" bash "$STATUSLINE")
elapsed=$(($(date +%s) - start))
assert "a hung herdr does not delay the status line" '((elapsed < 3)) && [[ "$out" == "$BASE" ]]'

LOG="$TMP_DIR/nopane.log"
: >"$LOG"
input side | env -u CLAUDE_PROFILE NO_COLOR=1 XDG_STATE_HOME="$STATE" HERDR_BIN_PATH="$FAKE_HERDR" HERDR_LOG="$LOG" \
  bash "$STATUSLINE" >/dev/null
input side | env CLAUDE_PROFILE=sentinel NO_COLOR=1 XDG_STATE_HOME="$STATE" HERDR_PANE_ID=p-1 \
  HERDR_BIN_PATH="$FAKE_HERDR" HERDR_LOG="$LOG" bash "$STATUSLINE" >/dev/null
wait_calls "$LOG"
assert "outside a herdr pane nothing is published" \
  '[[ "$(wc -l <"$LOG" | tr -d " ")" == 2 && "$(call "$LOG" 1)" == *"claude_profile=sentinel"* ]] && ! grep -q "claude_profile=default" "$LOG"'

echo ""
echo "statusline: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
