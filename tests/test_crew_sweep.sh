#!/usr/bin/env bash
set -euo pipefail

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_CONFIG_' || true)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWEEP="$REPO_ROOT/configs/claude-code/bin/crew-sweep"

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
    printf '        output: %s\n' "${OUT//$'\n'/$'\n        '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  command rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export CREW_RUNS_DIR="$TMP_DIR/runs"
export CREW_SWEEP_RETRY_WAIT=0.05
export FAKE_STATE="$TMP_DIR/state"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_STATE" "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Fake herdr: `agent list` prints $FAKE_STATE/agents.json and fails while the
# count in list_fail is above zero; `agent read` prints screen-<name>, or
# herdr's agent_not_found error with exit 1 when that file is absent.
cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_STATE
case "$1 $2" in
"agent list")
  n=$(cat "$d/list_fail" 2>/dev/null || echo 0)
  if ((n > 0)); then
    echo $((n - 1)) >"$d/list_fail"
    echo "herdr: cannot reach server socket" >&2
    exit 1
  fi
  cat "$d/agents.json"
  ;;
"agent read")
  if [[ -f $d/screen-$3 ]]; then
    cat "$d/screen-$3"
  else
    printf '{"error":{"code":"agent_not_found","message":"agent %s not found"}}\n' "$3"
    exit 1
  fi
  ;;
*)
  echo "fake herdr: unexpected $*" >&2
  exit 2
  ;;
esac
EOF

# Fake crew-role: prints $FAKE_STATE/role; role_mode fail:K fails the first K
# calls, slow:K makes the first K calls take three seconds.
cat >"$FAKE_BIN/crew-role" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_STATE
n=$(cat "$d/role_calls" 2>/dev/null || echo 0)
echo $((n + 1)) >"$d/role_calls"
mode=$(cat "$d/role_mode" 2>/dev/null || echo ok)
case $mode in
fail:*) if ((n < ${mode#fail:})); then echo "herdr pane list failed" >&2; exit 1; fi ;;
slow:*) if ((n < ${mode#slow:})); then sleep 3; fi ;;
esac
cat "$d/role"
EOF
chmod +x "$FAKE_BIN/herdr" "$FAKE_BIN/crew-role"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
REPO=$(cd "$REPO" && pwd -P)
CREW="$REPO/.claude/crew"
mkdir -p "$CREW/items"

set_role() {
  echo "$1" >"$FAKE_STATE/role"
  echo "${2:-ok}" >"$FAKE_STATE/role_mode"
  rm -f "$FAKE_STATE/role_calls"
}

# agents 'name status' ...; a name of null makes an unnamed agent.
agents() {
  local a name status pane=0
  for a in "$@"; do
    name=${a% *} status=${a##* } pane=$((pane + 1))
    jq -n --arg n "$name" --arg s "$status" --arg p "wB:p$pane" \
      '{name: (if $n == "null" then null else $n end), pane_id: $p, tab_id: "wB:t1", agent_status: $s, agent_session: {value: "s-\($p)"}}'
  done | jq -s '{result: {agents: .}}' >"$FAKE_STATE/agents.json"
}

# row id status owner [updated]
row() {
  printf '%s\t%s\t%s\tw/%s\tmain\t%s\tdeliver item %s\n' "$1" "$2" "$3" "$1" "${4:-0}" "$1"
}

now_ms() { echo $(($(date +%s%N) / 1000000)); }

RC=0
OUT=
ELAPSED=0
sweep() {
  local t0
  t0=$(now_ms)
  RC=0
  OUT=$(cd "$REPO" && "$SWEEP" "$@" 2>&1) || RC=$?
  ELAPSED=$(($(now_ms) - t0))
}

has() { grep -qxF -- "$1" <<<"$OUT"; }
has_re() { grep -qE -- "$1" <<<"$OUT"; }

set_role lead
agents
: >"$CREW/board.tsv"

echo "role check"
set_role none
{ row 1 done x-w1; row 2 blocked x-w2; } >"$CREW/board.tsv"
sweep 1
assert "a clean none prints SUPERSEDED" 'has SUPERSEDED'
assert "the role check comes before ALL-DONE" '! has ALL-DONE'

set_role lead fail:2
sweep 1
assert "a failing crew-role prints the error" 'has_re "^ERROR crew-role: .*herdr pane list failed"'
assert "a failing crew-role is retried until it answers" 'has ALL-DONE && [[ $(<"$FAKE_STATE/role_calls") == 3 ]]'
assert "a failing crew-role never gives SUPERSEDED" '! has SUPERSEDED'

set_role lead slow:1
sweep 1
assert "a crew-role run over two seconds prints an error" 'has_re "^ERROR crew-role: .*timed out"'
assert "a slow crew-role is retried" 'has ALL-DONE'
assert "a slow crew-role never gives SUPERSEDED" '! has SUPERSEDED'

set_role lead fail:1000
sweep 0
assert "a crew-role that keeps failing ends the sweep non-zero" '[[ $RC -ne 0 ]] && has_re "^ERROR crew-role"'
assert "a crew-role that keeps failing never gives SUPERSEDED" '! has SUPERSEDED'
set_role lead

echo "ALL-DONE"
{ row 1 done x-w1; row 2 blocked x-w2; row 3 done x-w3; } >"$CREW/board.tsv"
sweep 0
assert "one blocked row and the rest done prints ALL-DONE" 'has ALL-DONE && [[ $RC -eq 0 ]]'
{ row 1 done x-w1; printf '\n'; row 2 done x-w2; printf '\n'; } >"$CREW/board.tsv"
sweep 0
assert "blank lines do not stop ALL-DONE" 'has ALL-DONE'
printf '\n\n' >"$CREW/board.tsv"
sweep 0
assert "a board of blank lines is not ALL-DONE" '! has ALL-DONE'
: >"$CREW/board.tsv"
sweep 0
assert "an empty board is not ALL-DONE" '! has ALL-DONE'
rm "$CREW/board.tsv"
sweep 0
assert "a missing board is not ALL-DONE" '! has ALL-DONE && [[ $RC -eq 0 ]]'
{ row 1 done x-w1; row 2 open ''; } >"$CREW/board.tsv"
sweep 0
assert "an open row stops ALL-DONE" '! has ALL-DONE'
{ row 1 done x-w1; row 2 assigned x-w2; } >"$CREW/board.tsv"
agents 'x-w2 working'
sweep 0
assert "an assigned row stops ALL-DONE" '! has ALL-DONE'
{ row 1 done x-w1; printf '2\tfinished\tx-w2\tw/2\tmain\t0\tx\n'; } >"$CREW/board.tsv"
sweep 0
assert "a row with an unknown status is ignored" 'has ALL-DONE'

echo "item file changes"
{ row 1 open ''; } >"$CREW/board.tsv"
agents
rm -f "$CREW/.sweep-seen"
sweep 1
assert "with nothing changed the sweep waits for the timeout" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'

mkdir -p "$CREW/items/1"
(sleep 0.3 && echo "status: done" >"$CREW/items/1/report.md") &
sweep 5
assert "a new report ends the wait early" '[[ $ELAPSED -lt 3000 ]] && ! has TIMEOUT'
assert "the new report is listed" 'has "CHANGED $CREW/items/1/report.md"'

(sleep 0.3 && echo "main abc def" >"$CREW/items/1/merged") &
sweep 5
assert "a new merged file ends the wait early" '[[ $ELAPSED -lt 3000 ]]'
assert "only the merged file is listed" 'has "CHANGED $CREW/items/1/merged" && ! has_re "report.md"'

echo "verdict: green" >"$CREW/items/1/review.md"
sweep 5
assert "a review written between sweeps returns at once" '[[ $ELAPSED -lt 1000 ]]'
assert "the review written between sweeps is listed" 'has "CHANGED $CREW/items/1/review.md"'

sleep 0.05
echo "status: gone" >"$CREW/items/1/report.md"
sweep 5
assert "a same-size rewrite within one second counts as a change" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $CREW/items/1/report.md"'

rm "$CREW/items/1/merged"
sweep 5
assert "a removed file counts as a change" '[[ $ELAPSED -lt 1000 ]] && has "REMOVED $CREW/items/1/merged"'

echo "notes" >"$CREW/items/1/notes.md"
sweep 1
assert "notes.md is not watched" '[[ $ELAPSED -ge 1000 ]] && ! has_re CHANGED'

expected=$(cd "$CREW" && LC_ALL=C stat --printf '%n\t%.9Y\t%s\n' "$PWD/items/1/report.md" "$PWD/items/1/review.md" | LC_ALL=C sort)
assert ".sweep-seen holds path, nanosecond mtime and size" '[[ $(<"$CREW/.sweep-seen") == "$expected" ]]'

rm -rf "$CREW/items/1"
rm -f "$CREW/.sweep-seen"

echo "workers"
NOW=$(date +%s)
mkdir -p "$CREW/items"/{1..12}
{
  row 1 assigned x-w1 "$NOW"
  row 2 assigned x-w2 "$NOW"
  row 3 assigned x-w3 "$NOW"
  row 4 assigned x-w4 "$NOW"
  row 5 assigned x-w5 "$NOW"
  row 6 assigned x-w6 "$NOW"
  row 7 assigned x-w7 "$NOW"
  row 8 assigned x-w8 "$NOW"
  row 9 assigned x-w9 "$NOW"
  row 10 assigned x-w10 "$NOW"
  row 11 assigned x-w11 soon
  row 12 done x-w12 "$NOW"
} >"$CREW/board.tsv"
echo "status: question" >"$CREW/items/7/report.md"
touch -d "@$((NOW + 5))" "$CREW/items/7/report.md"
echo "status: done" >"$CREW/items/10/report.md"
touch -d "@$((NOW - 60))" "$CREW/items/10/report.md"
echo "status: done" >"$CREW/items/11/report.md"
touch -d "@$((NOW - 60))" "$CREW/items/11/report.md"

# The merging file crew-merge writes: one `key value` per line, `pid`, `start`
# (token 20 after the last ") " of /proc/<pid>/stat) and `tip` at step 0, then
# `merged <sha>` appended at step 5; the last line for a key wins.
sleep 30 &
LIVE=$!
PIDS+=("$LIVE")
live_start=$(awk '{print $22}' "/proc/$LIVE/stat")
printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$live_start" 0 >"$CREW/items/8/merging"
printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$((live_start + 1))" 0 >"$CREW/items/9/merging"

printf 'Allow this command?\n  1. Yes\n  2. No\n\n\n' >"$FAKE_STATE/screen-x-w3"
agents 'x-w1 idle' 'x-w2 working' 'x-w3 blocked' 'x-w5 unknown' 'x-w6 blocked' \
  'x-w7 done' 'x-w8 idle' 'x-w9 idle' 'x-w10 done' 'x-w11 working' 'x-w12 idle' \
  'x-lead idle' 'x-old1 idle' 'null working' 'mine idle'
sweep 1
assert "an idle owner with no report since its update is IDLE" 'has "WORKER x-w1 item 1 idle IDLE"'
assert "a working owner has no flags" 'has "WORKER x-w2 item 2 working"'
assert "a blocked owner is DIALOG" 'has "WORKER x-w3 item 3 blocked DIALOG"'
assert "a DIALOG is followed by the screen's last lines, indented" 'has "  Allow this command?" && has "    2. No"'
assert "an owner missing from the list is only GONE" 'has "GONE x-w4" && ! has_re "x-w4 "'
assert "an owner with status unknown is not GONE" 'has "WORKER x-w5 item 5 unknown" && ! has "GONE x-w5"'
assert "agent_not_found between list and read counts as GONE" 'has "GONE x-w6" && ! has_re "WORKER x-w6"'
assert "a rate-limited owner (done) with a newer report is not IDLE" 'has "WORKER x-w7 item 7 done"'
assert "a live merging pid with the recorded start shows MERGING instead of IDLE" 'has "WORKER x-w8 item 8 idle MERGING"'
assert "a reused merging pid is not MERGING" 'has "WORKER x-w9 item 9 idle IDLE"'
assert "a done owner with only an older report is IDLE" 'has "WORKER x-w10 item 10 done IDLE"'
assert "an unparseable updated counts as 0" 'has "WORKER x-w11 item 11 working"'
assert "owners of rows that are not assigned are not listed" '! has_re "x-w12"'
assert "the lead, -old panes, unnamed and unrelated agents are not listed" '! has_re "x-lead|x-old1|null|mine"'
assert "each assigned row prints exactly one line of its own" '[[ $(grep -cE "^(WORKER|GONE) " <<<"$OUT") -eq 11 ]]'

agents 'x-w1 done'
printf 'Usage limit reached\n' >"$FAKE_STATE/screen-x-w1"
{ row 1 assigned x-w1 "$NOW"; } >"$CREW/board.tsv"
sweep 1
assert "a rate-limited owner (done, no report) is IDLE" 'has "WORKER x-w1 item 1 done IDLE"'

kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
{ row 8 assigned x-w8 "$NOW"; } >"$CREW/board.tsv"
agents 'x-w8 idle'
sweep 1
assert "a dead merging pid is not MERGING" 'has "WORKER x-w8 item 8 idle IDLE"'

cp "$(command -v sleep)" "$TMP_DIR/my sleep"
"$TMP_DIR/my sleep" 30 &
SPACED=$!
PIDS+=("$SPACED")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ $(cat "/proc/$SPACED/comm" 2>/dev/null) == "my sleep" ]] && break
  sleep 0.05
done
spaced_start=$(awk '{print $23}' "/proc/$SPACED/stat")
printf 'pid %s\nstart %s\ntip %040d\n' "$SPACED" "$spaced_start" 0 >"$CREW/items/8/merging"
sweep 1
assert "the start time is read past a process name holding a space" 'has "WORKER x-w8 item 8 idle MERGING"'
printf 'pid %s\nstart %s\ntip %040d\nmerged %040d\n' "$SPACED" "$spaced_start" 0 1 >"$CREW/items/8/merging"
sweep 1
assert "a merging file with a merged line is still read" 'has "WORKER x-w8 item 8 idle MERGING"'
printf 'garbage\n' >"$CREW/items/8/merging"
sweep 1
assert "an unparseable merging file is not MERGING" 'has "WORKER x-w8 item 8 idle IDLE"'
rm "$CREW/items/8/merging"

echo "herdr agent list failures"
{ row 1 assigned x-w1 "$NOW"; } >"$CREW/board.tsv"
agents 'x-w1 working'
echo 2 >"$FAKE_STATE/list_fail"
sweep 0
assert "a failing agent list prints the error" 'has_re "^ERROR herdr agent list: .*cannot reach server socket"'
assert "a failing agent list is retried" 'has "WORKER x-w1 item 1 working"'
assert "a failing agent list never gives GONE" '! has_re "^GONE"'
echo 1000 >"$FAKE_STATE/list_fail"
sweep 0
assert "an agent list that keeps failing ends the sweep non-zero without GONE" '[[ $RC -ne 0 ]] && ! has_re "^GONE"'
rm "$FAKE_STATE/list_fail"
echo 'not json' >"$FAKE_STATE/agents.json"
sweep 0
assert "unparseable agent list output is an error, not GONE" '[[ $RC -ne 0 ]] && has_re "^ERROR herdr agent list" && ! has_re "^GONE"'

echo "worker role"
set_role worker
sweep 0
assert "a worker running the sweep gets an error, not SUPERSEDED" '[[ $RC -ne 0 ]] && ! has SUPERSEDED'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
