#!/usr/bin/env bash
set -euo pipefail

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_CONFIG_' || true)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SWEEP="$REPO_ROOT/configs/claude-code/bin/crew-sweep"
# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

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
export CREW_QUIET=1000000
export CREW_DISK_MIN_GB=0 CREW_MEM_MIN_MB=0 CREW_LOAD_PER_CPU=1000000 CREW_IO_FULL_PCT=1000
export FAKE_STATE="$TMP_DIR/state"
export XDG_STATE_HOME="$TMP_DIR/xdg"
USAGE="$XDG_STATE_HOME/harness/usage/sessions"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_STATE" "$FAKE_BIN" "$USAGE"
# shellcheck source=lib/path-without.sh
. "$SCRIPT_DIR/lib/path-without.sh"
unset ANTHROPIC_API_KEY
export XDG_DATA_HOME="$TMP_DIR/data"
OPENCODE_AUTH="$XDG_DATA_HOME/opencode/auth.json"
OPENCODE_BIN="$TMP_DIR/opencode-bin"
mkdir -p "$OPENCODE_BIN" "${OPENCODE_AUTH%/*}"
printf '#!/usr/bin/env bash\nexit 0\n' >"$OPENCODE_BIN/opencode"
chmod +x "$OPENCODE_BIN/opencode"
export PATH="$FAKE_BIN:$(path_without opencode "$TMP_DIR")"

# Fake herdr: `agent list` prints $FAKE_STATE/agents.json and fails while the
# count in list_fail is above zero, or once the count in list_ok has run out;
# `agent read` prints screen-<name>, or herdr's agent_not_found error with
# exit 1 when that file is absent; `tab list` prints tabs.json.
cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_STATE
case "$1 $2" in
"agent list")
  if [[ -f $d/list_ok ]]; then
    n=$(cat "$d/list_ok")
    if ((n <= 0)); then
      echo "herdr: cannot reach server socket" >&2
      exit 1
    fi
    echo $((n - 1)) >"$d/list_ok"
  fi
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
"tab list") cat "$d/tabs.json" ;;
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

# Fake crew-dagr: appends a line to dagr_calls; with dagr_fail present it also
# writes to stderr and fails.
cat >"$FAKE_BIN/crew-dagr" <<'EOF'
#!/usr/bin/env bash
echo call >>"$FAKE_STATE/dagr_calls"
if [[ -f $FAKE_STATE/dagr_fail ]]; then
  echo "crew-dagr: dagr check failed" >&2
  exit 1
fi
EOF
# Fake claude-profile: `names` prints $FAKE_STATE/profiles.
cat >"$FAKE_BIN/claude-profile" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == names ]]; then cat "$FAKE_STATE/profiles" 2>/dev/null; fi
EOF
# Fake ps: `ps -o lstart= -p <pid>` prints $FAKE_STATE/ps-start-<pid> when it
# exists, so a live pid can pass for one started long ago; anything else runs
# the real ps.
REAL_PS=$(command -v ps)
export REAL_PS
cat >"$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
if [[ $# -eq 4 && "$1 $2 $3" == "-o lstart= -p" && -f $FAKE_STATE/ps-start-$4 ]]; then
  cat "$FAKE_STATE/ps-start-$4"
  exit 0
fi
exec "$REAL_PS" "$@"
EOF
chmod +x "$FAKE_BIN/herdr" "$FAKE_BIN/crew-role" "$FAKE_BIN/crew-dagr" "$FAKE_BIN/claude-profile" "$FAKE_BIN/ps"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
REPO=$(cd "$REPO" && pwd -P)
CREW="$REPO/.claude/crew"
mkdir -p "$CREW/items" "$REPO/sub"
date >"$CREW/reflections.md"

set_role() {
  echo "$1" >"$FAKE_STATE/role"
  echo "${2:-ok}" >"$FAKE_STATE/role_mode"
  rm -f "$FAKE_STATE/role_calls"
}

# agents 'name status [session] [kind]' ...; agent N sits in pane wB:pN. A name
# of null makes an unnamed agent, a session of - leaves agent_session out as
# herdr does for opencode, and without a session the agent gets one with no
# usage file. The kind defaults to claude.
agents() {
  local a name status sid kind pane=0
  for a in "$@"; do
    read -r name status sid kind <<<"$a"
    pane=$((pane + 1))
    jq -n --arg n "$name" --arg s "$status" --arg p "wB:p$pane" --arg sid "${sid:-s-p$pane}" --arg k "${kind:-claude}" \
      '{name: (if $n == "null" then null else $n end), agent: $k, pane_id: $p, tab_id: "wB:t1", agent_status: $s}
        + (if $sid == "-" then {} else {agent_session: {value: $sid}} end)'
  done | jq -s '{result: {agents: .}}' >"$FAKE_STATE/agents.json"
}

tabs() {
  jq -n '{result: {tabs: [$ARGS.positional[] | {label: ., tab_id: ("t-" + .)}]}}' --args "$@" >"$FAKE_STATE/tabs.json"
}

# usage session profile tokens window session_pct session_resets week_pct
# week_resets writes the statusline's usage file; null stands for a missing figure.
usage() {
  jq -n --arg p "$2" --argjson t "$3" --argjson w "$4" --argjson sp "$5" --argjson sr "$6" \
    --argjson wp "$7" --argjson wr "$8" \
    '{profile: $p, context_tokens: $t, context_window: $w, session: {pct: $sp, resets: $sr}, week: {pct: $wp, resets: $wr}}' \
    >"$USAGE/$1.json.tmp"
  mv "$USAGE/$1.json.tmp" "$USAGE/$1.json"
}

# row id status owner [updated] [deps]; without deps the row has seven columns.
row() {
  printf '%s\t%s\t%s\tw/%s\tmain\t%s\tdeliver item %s' "$1" "$2" "$3" "$1" "${4:-0}" "$1"
  [[ -z ${5+x} ]] || printf '\t%s' "$5"
  printf '\n'
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
without_pool() { grep -vE '^(POOL|SPARE|LEFTOVER) ' <<<"$OUT" || true; }

set_role lead
agents
tabs
: >"$CREW/board.tsv"

echo "role check"
set_role none
{
  row 1 done x-w1
  row 2 blocked x-w2
} >"$CREW/board.tsv"
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
{
  row 1 done x-w1
  row 2 blocked x-w2
  row 3 done x-w3
} >"$CREW/board.tsv"
sweep 0
assert "one blocked row and the rest done prints ALL-DONE" 'has ALL-DONE && [[ $RC -eq 0 ]]'
{
  row 1 done x-w1
  printf '\n'
  row 2 done x-w2
  printf '\n'
} >"$CREW/board.tsv"
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
{
  row 1 done x-w1
  row 2 open ''
} >"$CREW/board.tsv"
sweep 0
assert "an open row stops ALL-DONE" '! has ALL-DONE'
{
  row 1 done x-w1
  row 2 assigned x-w2
} >"$CREW/board.tsv"
agents 'x-w2 working'
sweep 0
assert "an assigned row stops ALL-DONE" '! has ALL-DONE'
{
  row 1 done x-w1
  printf '2\tfinished\tx-w2\tw/2\tmain\t0\tx\n'
} >"$CREW/board.tsv"
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
sweep 1
assert "review.md is not watched" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && ! has_re "review.md"'

sleep 0.05
echo "status: done" >"$CREW/items/1/report.md"
sweep 5
assert "a same-content rewrite of a report with no at: line counts as a change" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $CREW/items/1/report.md"'

rm "$CREW/items/1/merged"
sweep 5
assert "a removed file counts as a change" '[[ $ELAPSED -lt 1000 ]] && has "REMOVED $CREW/items/1/merged"'

echo "notes" >"$CREW/items/1/notes.md"
sweep 1
assert "notes.md is not watched" '[[ $ELAPSED -ge 1000 ]] && ! has_re CHANGED'

expected=$(printf 'v2\n%s\tstat %s' "$CREW/items/1/report.md" "$(stat --printf '%.9Y %s' "$CREW/items/1/report.md")")
assert ".sweep-seen starts with v2 and keys a report with no at: line on its mtime and size" '[[ $(<"$CREW/.sweep-seen") == "$expected" ]]'

rm -rf "$CREW/items/1"
rm -f "$CREW/.sweep-seen"

echo "content keys"
report() { printf 'status: %s\nat: %s\n' "$2" "$3" >"$1"; }
seen_key() { awk -F'\t' -v p="$1" '$1 == p { print $2 }' "$CREW/.sweep-seen"; }
R="$CREW/items/1/report.md"
mkdir -p "$CREW/items/1"
report "$R" working t1
sweep 0
report "$R" working t2
sweep 1
assert "a progress rewrite with a status that needs no action does not wake" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'
(sleep 0.3 && report "$R" question t3) &
sweep 5
assert "a new question during the wait wakes" '[[ $ELAPSED -lt 3000 ]] && has "CHANGED $R"'
touch "$R"
sweep 1
assert "touching a report with an at: line does not wake" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'
report "$R" question t3
sweep 1
assert "an identical rewrite of a report with an at: line does not wake" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'
report "$R" "rate-limited resets 3pm" t4
sweep 1
assert "a rate-limited status with a reset time wakes" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $R"'
report "$R" working t5
sweep 1
assert "a change to a status that needs no action wakes once" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $R"'
report "$R" working t6
sweep 1
assert "the next progress rewrite does not wake" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'
report "$R" Done t7
sweep 0
report "$R" Done t8
sweep 1
assert "a rewrite of a report with an unrecognized status wakes, so it is never hidden" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $R"'
rm -rf "$CREW/items" "$CREW/.sweep-seen"

statuses=(done question 'rate-limited resets 3pm' 'done   ' doneish Done working)
words=(done question rate-limited done doneish '' working)
for i in "${!statuses[@]}"; do
  mkdir -p "$CREW/items/a$i"
  report "$CREW/items/a$i/report.md" "${statuses[$i]}" t1
done
echo "main abc def" >"$CREW/items/a0/merged"
sweep 0
agree=1
for i in "${!statuses[@]}"; do
  f="$CREW/items/a$i/report.md"
  w=$(crew_report_word "$f")
  [[ $w == "${words[$i]}" ]] || agree=0
  if [[ $w =~ ^(done|question|blocked|handoff|rate-limited)$ ]]; then
    [[ $(seen_key "$f") == "sha $(sha1sum <"$f" | cut -c1-40)" ]] || agree=0
  elif [[ $w == working ]]; then
    [[ $(seen_key "$f") == - ]] || agree=0
  else
    [[ $(seen_key "$f") == "stat $(stat --printf '%.9Y %s' "$f")" ]] || agree=0
  fi
done
assert "crew_report_word and the snapshot agree on each status word" '((agree))'
assert "a merged file is keyed on its sha1" '[[ $(seen_key "$CREW/items/a0/merged") == "sha $(sha1sum <"$CREW/items/a0/merged" | cut -c1-40)" ]]'

REAL_SHA1SUM=$(command -v sha1sum)
export REAL_SHA1SUM
cat >"$FAKE_BIN/sha1sum" <<'EOF'
#!/usr/bin/env bash
echo "$#" >>"$FAKE_STATE/sha1sum_calls"
exec "$REAL_SHA1SUM" "$@"
EOF
chmod +x "$FAKE_BIN/sha1sum"
rm -f "$FAKE_STATE/sha1sum_calls"
sweep 3
assert "a quiet wait hashes files only on its first poll" '[[ $ELAPSED -ge 3000 ]] && has TIMEOUT && [[ $(grep -cvx 0 "$FAKE_STATE/sha1sum_calls") -eq 1 ]]'
rm "$FAKE_BIN/sha1sum"
rm -rf "$CREW/items" "$CREW/.sweep-seen"

echo "re-raise"
mkdir -p "$CREW/items/1"
{ row 1 assigned x-w1 "$(($(date +%s) - 100))"; } >"$CREW/board.tsv"
agents 'x-w1 working'
echo "status: question" >"$R"
sweep 0
{ row 1 assigned x-w1 "$(($(date +%s) + 1))"; } >"$CREW/board.tsv"
echo "status: question" >"$R"
sweep 1
assert "an identical rewrite of an answered question with no at: line wakes" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $R"'
report "$R" question t1
sweep 0
{ row 1 assigned x-w1 "$(($(date +%s) + 1))"; } >"$CREW/board.tsv"
report "$R" question t2
sweep 1
assert "the same question rewritten with a new at: line after the answer wakes" '[[ $ELAPSED -lt 1000 ]] && has "CHANGED $R"'
rm -rf "$CREW/items" "$CREW/.sweep-seen"
{ row 1 open ''; } >"$CREW/board.tsv"
agents

echo "old .sweep-seen"
old_seen() {
  stat --printf '%n\t%.9Y\t%s\n' "$CREW/items/1/report.md" "$CREW/items/1/review.md" \
    "$CREW/items/2/report.md" "$CREW/items/3/merged" | LC_ALL=C sort >"$CREW/.sweep-seen"
}
mkdir -p "$CREW/items"/{1,2,3}
echo "status: done" >"$CREW/items/1/report.md"
report "$CREW/items/2/report.md" question t1
echo "verdict: green" >"$CREW/items/1/review.md"
echo "main abc def" >"$CREW/items/3/merged"
old_seen
sweep 1
assert "an old-format .sweep-seen with nothing changed waits out the wait" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && ! has_re "^(CHANGED|REMOVED) "'
assert "an old-format .sweep-seen is rewritten in the new format" '[[ $(head -n 1 "$CREW/.sweep-seen") == v2 && $(wc -l <"$CREW/.sweep-seen") -eq 4 ]] && ! grep -q review.md "$CREW/.sweep-seen"'
old_seen
touch -d "@$(($(date +%s) - 50))" "$CREW/items/2/report.md"
rm "$CREW/items/3/merged"
sweep 1
expected=$(printf 'CHANGED %s\nREMOVED %s' "$CREW/items/2/report.md" "$CREW/items/3/merged")
assert "an old-format .sweep-seen lists only the paths whose stat line differs or that are gone" '[[ $ELAPSED -lt 1000 && $(grep -E "^(CHANGED|REMOVED) " <<<"$OUT") == "$expected" ]]'
rm -rf "$CREW/items" "$CREW/.sweep-seen"

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
# (crew_pid_start of that pid) and `tip` at step 0, then
# `merged <sha>` appended at step 5; the last line for a key wins.
sleep 30 &
LIVE=$!
PIDS+=("$LIVE")
live_start=$(crew_pid_start "$LIVE")
printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$live_start" 0 >"$CREW/items/8/merging"
printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$((live_start + 1))" 0 >"$CREW/items/9/merging"

printf 'Allow this command?\n  1. Yes\n  2. No\n\n\n' >"$FAKE_STATE/screen-x-w3"
agents 'x-w1 idle' 'x-w2 working' 'x-w3 blocked' 'x-w5 unknown' 'x-w6 blocked' \
  'x-w7 done' 'x-w8 idle' 'x-w9 idle' 'x-w10 done' 'x-w11 working' 'x-w12 idle' \
  'x-lead idle' 'x-old1 idle' 'null working' 'mine idle'
sweep 1
assert "an idle owner with no report since its update is IDLE" 'has "WORKER x-w1 item 1 idle on ? IDLE"'
assert "a working owner has no flags" 'has "WORKER x-w2 item 2 working on ?"'
assert "a blocked owner is DIALOG" 'has "WORKER x-w3 item 3 blocked on ? DIALOG"'
assert "a DIALOG is followed by the screen's last lines, indented" 'has "  Allow this command?" && has "    2. No"'
assert "an owner missing from the list is only GONE" 'has "GONE x-w4" && ! has_re "x-w4 "'
assert "an owner with status unknown is not GONE" 'has "WORKER x-w5 item 5 unknown on ?" && ! has "GONE x-w5"'
assert "agent_not_found between list and read counts as GONE" 'has "GONE x-w6" && ! has_re "WORKER x-w6"'
assert "a rate-limited owner (done) with a newer report is not IDLE" 'has "WORKER x-w7 item 7 done on ?"'
assert "a live merging pid with the recorded start shows MERGING instead of IDLE" 'has "WORKER x-w8 item 8 idle on ? MERGING"'
assert "a reused merging pid is not MERGING" 'has "WORKER x-w9 item 9 idle on ? IDLE"'
assert "a dead merging marker is STALE-MERGE and a live one is not" 'has "STALE-MERGE 9" && ! has "STALE-MERGE 8"'
assert "a done owner with only an older report is IDLE" 'has "WORKER x-w10 item 10 done on ? IDLE"'
assert "an unparseable updated counts as 0" 'has "WORKER x-w11 item 11 working on ?"'
assert "owners of rows that are not assigned are not listed" '! has_re "x-w12"'
assert "the lead, -old panes, unnamed and unrelated agents are not listed" '! has_re "x-lead|x-old1|null|mine"'
assert "each assigned row prints exactly one line of its own" '[[ $(grep -cE "^(WORKER|GONE) " <<<"$OUT") -eq 11 ]]'
rm "$CREW/items/9/merging"

agents 'x-w1 done'
printf 'Usage limit reached\n' >"$FAKE_STATE/screen-x-w1"
{ row 1 assigned x-w1 "$NOW"; } >"$CREW/board.tsv"
sweep 1
assert "a rate-limited owner (done, no report) is IDLE" 'has "WORKER x-w1 item 1 done on ? IDLE"'

kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
{ row 8 assigned x-w8 "$NOW"; } >"$CREW/board.tsv"
agents 'x-w8 idle'
mkdir -p "$CREW/items/13"
printf 'pid %s\nstart 1\ntip %040d\nmerged %040d\n' "$LIVE" 0 1 >"$CREW/items/13/merging"
sweep 1
assert "a dead merging pid is not MERGING" 'has "WORKER x-w8 item 8 idle on ? IDLE"'
assert "a dead merging pid is STALE-MERGE" 'has "STALE-MERGE 8"'
assert "a cut marker of an item with no assigned row is STALE-MERGE" 'has "STALE-MERGE 13"'
rm -r "$CREW/items/13"
printf '8\tassigned\tx-w8\t\tmain\t%s\tx\n' "$NOW" >"$CREW/board.tsv"
echo "status: done" >"$CREW/items/8/report.md"
touch -d "@$((NOW - 60))" "$CREW/items/8/report.md"
sweep 1
assert "an empty column keeps updated in place" 'has "WORKER x-w8 item 8 idle on ? IDLE"'
rm "$CREW/items/8/report.md"
{ row 8 assigned x-w8 "$NOW"; } >"$CREW/board.tsv"

sleep 30 &
LIVE=$!
PIDS+=("$LIVE")
live_start=$(crew_pid_start "$LIVE")
printf 'pid %s\nstart %s\ntip %040d\nmerged %040d\n' "$LIVE" "$live_start" 0 1 >"$CREW/items/8/merging"
sweep 1
assert "a merging file with a merged line is still read" 'has "WORKER x-w8 item 8 idle on ? MERGING" && ! has_re "^STALE-MERGE"'
printf 'garbage\n' >"$CREW/items/8/merging"
sweep 1
assert "an unparseable merging file is not MERGING" 'has "WORKER x-w8 item 8 idle on ? IDLE"'
assert "an unparseable merging file is STALE-MERGE" 'has "STALE-MERGE 8"'
rm "$CREW/items/8/merging"

echo "herdr agent list failures"
{ row 1 assigned x-w1 "$NOW"; } >"$CREW/board.tsv"
agents 'x-w1 working'
echo 3 >"$FAKE_STATE/list_fail"
sweep 0
assert "a failing agent list prints the error" 'has_re "^ERROR herdr agent list: .*cannot reach server socket"'
assert "a failing agent list is retried" 'has "WORKER x-w1 item 1 working on ?"'
assert "a failing agent list never gives GONE" '! has_re "^GONE"'
echo 1000 >"$FAKE_STATE/list_fail"
sweep 0
assert "an agent list that keeps failing ends the sweep non-zero without GONE" '[[ $RC -ne 0 ]] && ! has_re "^GONE"'
rm "$FAKE_STATE/list_fail"
echo 'not json' >"$FAKE_STATE/agents.json"
sweep 0
assert "unparseable agent list output is an error, not GONE" '[[ $RC -ne 0 ]] && has_re "^ERROR herdr agent list" && ! has_re "^GONE"'

echo "dagr publishing"
dagr_calls() { cat "$FAKE_STATE/dagr_calls" 2>/dev/null | wc -l; }
{ row 1 open ''; } >"$CREW/board.tsv"
agents
rm -f "$FAKE_STATE/dagr_calls"
set_role none
sweep 1
assert "nothing is published after SUPERSEDED" '[[ $(dagr_calls) -eq 0 ]]'
set_role lead

{ row 1 done x-w1; } >"$CREW/board.tsv"
sweep 1
assert "ALL-DONE publishes once, after the role check" 'has ALL-DONE && [[ $(dagr_calls) -eq 1 ]]'

{ row 1 open ''; } >"$CREW/board.tsv"
rm -f "$FAKE_STATE/dagr_calls"
sweep 1
assert "a wait shorter than the interval publishes at start and at exit" 'has TIMEOUT && [[ $(dagr_calls) -eq 2 ]]'

rm -f "$FAKE_STATE/dagr_calls"
OUT=$(cd "$REPO" && CREW_DAGR_INTERVAL=1 "$SWEEP" 3 2>&1) || true
assert "the wait publishes on every interval" '[[ $(dagr_calls) -ge 4 ]]'

touch "$FAKE_STATE/dagr_fail"
{ row 1 open ''; } >"$CREW/board.tsv"
sweep 0
assert "a failing crew-dagr changes neither output nor exit status" '[[ $RC -eq 0 && $(without_pool) == $'"'"'TIMEOUT\nREADY 1'"'"' ]]'
{ row 1 done x-w1; } >"$CREW/board.tsv"
sweep 0
assert "a failing crew-dagr does not fail ALL-DONE" '[[ $RC -eq 0 && $(without_pool) == ALL-DONE ]]'
rm "$FAKE_STATE/dagr_fail"

echo "ready and deps"
NOW=$(date +%s)
rm -rf "$CREW/items" "$CREW/.sweep-seen"
mkdir -p "$CREW/items"
{
  row 1 done x-w1 "$NOW"
  row 2 open ''
  row 3 open '' 0 1
  row 4 open '' 0 1,2
  row 5 assigned x-w5 "$NOW"
  row 6 open '' 0 5
  row 7 blocked x-w7 "$NOW"
  row 8 open '' 0 7
  row 9 open '' 0 8
  row 10 open '' 0 99
  printf '11\tfinished\tx-w11\tw/11\tmain\t0\tx\n'
  row 12 open '' 0 11
  row 13 open '' 0 14
  row 14 open '' 0 13
  row 15 assigned x-w15 "$NOW" 1
  row 16 open '' 0 13
  row 17 open '' 0 17
  row 18 open '' 0 ' 1 '
} >"$CREW/board.tsv"
agents 'x-w5 working' 'x-w15 working'
sweep 1
assert "an open row with no deps is READY" 'has "READY 2"'
assert "an open row whose deps are all done is READY" 'has "READY 3"'
assert "a dep that is open, assigned or blocked holds READY back" '! has_re "^READY (4|6|8)$"'
assert "assigned and done rows are never READY" '! has_re "^READY (1|5|15)$"'
assert "deps that can still finish give no DEPS line" '! has_re "^DEPS (2|3|4|6) "'
assert "a direct blocked dep is named" 'has "DEPS 8 waits on blocked 7"'
assert "a blocked dep through an open row is named" 'has "DEPS 9 waits on blocked 7"'
assert "a dep with no row is unknown" 'has "DEPS 10 names unknown 99"'
assert "a dep on a row with an unknown status is unknown" 'has "DEPS 12 names unknown 11"'
assert "a two-row cycle is named on both rows" 'has "DEPS 13 is in a cycle" && has "DEPS 14 is in a cycle"'
assert "a row that depends on itself is in a cycle" 'has "DEPS 17 is in a cycle"'
assert "a row waiting on a cycle names the stuck row" 'has "DEPS 16 waits on stuck 13"'
assert "spaces around dep ids are ignored" 'has "READY 18"'
assert "each stuck row gets exactly one DEPS line" '[[ $(grep -c "^DEPS " <<<"$OUT") -eq 8 ]]'
assert "READY never shortens the wait" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'
{
  row 1 done x-w1 "$NOW"
  row 2 open '' 0 1
  row 3 open '' 0 2
} >"$CREW/board.tsv"
sweep 0
assert "only the head of a chain is READY" 'has "READY 2" && ! has "READY 3" && ! has_re "^DEPS"'
{
  row 1 done x-w1 "$NOW"
  row 2 done x-w2 "$NOW" 1
} >"$CREW/board.tsv"
sweep 0
assert "ALL-DONE comes before READY and DEPS" '[[ $(without_pool) == ALL-DONE ]]'

echo "quiet"
export CREW_QUIET=100
NOW=$(date +%s)
OLD=$((NOW - 1000))
rm -rf "$CREW/items" "$CREW/.sweep-seen"
mkdir -p "$CREW/items"/{1..12}
gc() { git -C "$REPO" -c user.name=t -c user.email=t@example.com "$@"; }
tree=$(gc mktree </dev/null)
gc update-ref refs/heads/w/3 "$(GIT_COMMITTER_DATE="$NOW +0000" gc commit-tree -m new "$tree")"
gc update-ref refs/heads/w/4 "$(GIT_COMMITTER_DATE="$OLD +0000" gc commit-tree -m old "$tree")"
sleep 30 &
LIVE=$!
PIDS+=("$LIVE")
live_start=$(crew_pid_start "$LIVE")
{
  for i in 1 2 3 4 5 6 7 8 9; do row "$i" assigned "x-w$i" "$OLD"; done
  row 10 assigned x-w10 "$NOW"
  row 11 assigned x-w11 soon
  row 12 assigned x-w12 "$OLD"
} >"$CREW/board.tsv"
echo "test red" >"$CREW/items/2/notes.md"
printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$live_start" 0 >"$CREW/items/5/merging"
printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$live_start" 0 >"$CREW/items/6/merging"
touch -d "@$OLD" "$CREW/items/6/merging"
printf 'pid %s\nstart %s\ntip %040d\nqueued %s\n' "$LIVE" "$live_start" 0 "$OLD" >"$CREW/items/12/merging"
touch -d "@$OLD" "$CREW/items/12/merging"
echo "status: question" >"$CREW/items/7/report.md"
touch -d "@$((OLD + 10))" "$CREW/items/7/report.md"
echo "status: blocked" >"$CREW/items/8/report.md"
touch -d "@$((OLD + 10))" "$CREW/items/8/report.md"
echo "status: question" >"$CREW/items/9/report.md"
touch -d "@$((OLD - 10))" "$CREW/items/9/report.md"
agents 'x-w1 idle' 'x-w2 working' 'x-w3 working' 'x-w4 working' 'x-w5 working' 'x-w6 working' \
  'x-w7 working' 'x-w8 working' 'x-w9 working' 'x-w10 working' 'x-w11 working' 'x-w12 working'
sweep 0
assert "no progress inside the interval is QUIET, after IDLE" 'has "WORKER x-w1 item 1 idle on ? IDLE QUIET"'
assert "a newer notes.md is progress" 'has "WORKER x-w2 item 2 working on ?"'
assert "a newer commit on the item branch is progress" 'has "WORKER x-w3 item 3 working on ?"'
assert "an old commit on the item branch is not progress" 'has "WORKER x-w4 item 4 working on ? QUIET"'
assert "a fresh live merging file is not QUIET" 'has "WORKER x-w5 item 5 working on ? MERGING"'
assert "a live merging file older than the interval is MERGING QUIET" 'has "WORKER x-w6 item 6 working on ? MERGING QUIET"'
assert "a current question report is not QUIET" 'has "WORKER x-w7 item 7 working on ?"'
assert "a current blocked report is not QUIET" 'has "WORKER x-w8 item 8 working on ?"'
assert "a question report older than the row update is QUIET again" 'has "WORKER x-w9 item 9 working on ? QUIET"'
assert "a recent row update is progress" 'has "WORKER x-w10 item 10 working on ?"'
assert "an unparseable updated counts as 0 for QUIET" 'has "WORKER x-w11 item 11 working on ? QUIET"'
assert "a merge queued longer than the interval is MERGING, never QUIET" 'has "WORKER x-w12 item 12 working on ? MERGING"'
kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
export CREW_QUIET=1000000

echo "reflect"
rm -rf "$CREW/items" "$CREW/.sweep-seen"
{ row 1 open ''; } >"$CREW/board.tsv"
agents
rm "$CREW/reflections.md"
sweep 0
assert "a missing reflections.md prints REFLECT" 'has REFLECT'
date >"$CREW/reflections.md"
sweep 0
assert "a fresh reflections.md prints no REFLECT" '! has REFLECT'
touch -d "@$(($(date +%s) - 200))" "$CREW/reflections.md"
export CREW_REFLECT_EVERY=100
sweep 0
assert "a reflections.md older than the interval prints REFLECT" 'has REFLECT'
unset CREW_REFLECT_EVERY
sweep 0
assert "the default interval is longer than 200 seconds" '! has REFLECT'
date >"$CREW/reflections.md"
{ row 1 done x-w1; } >"$CREW/board.tsv"
rm "$CREW/reflections.md"
sweep 0
assert "ALL-DONE comes before REFLECT" '[[ $(without_pool) == ALL-DONE ]]'
date >"$CREW/reflections.md"
{ row 1 open ''; } >"$CREW/board.tsv"

echo "sweep-check"
cat >"$CREW/sweep-check" <<'EOF'
#!/usr/bin/env bash
seq 1 25
pwd
echo "locks=${GIT_OPTIONAL_LOCKS:-unset}"
EOF
chmod +x "$CREW/sweep-check"
RC=0
OUT=$(cd "$REPO/sub" && "$SWEEP" 0 2>&1) || RC=$?
assert "sweep-check runs in the main checkout" 'has "CHECK $REPO"'
assert "sweep-check runs with optional git locks off" 'has "CHECK locks=0"'
assert "sweep-check output is capped to its last 20 lines" '[[ $(grep -c "^CHECK " <<<"$OUT") -eq 20 ]] && has "CHECK 8" && ! has "CHECK 7"'
assert "a passing sweep-check prints no failure" '[[ $RC -eq 0 ]] && ! has_re "^CHECK failed"'

printf '#!/usr/bin/env bash\necho bad\nexit 3\n' >"$CREW/sweep-check"
sweep 0
assert "a failing sweep-check prints its output and exit status" 'has "CHECK bad" && has "CHECK failed: sweep-check exited 3"'
assert "a failing sweep-check is not an ERROR and keeps exit 0" '[[ $RC -eq 0 ]] && ! has_re "^ERROR"'
printf '#!/usr/bin/env bash\nprintf partial\nexit 3\n' >"$CREW/sweep-check"
sweep 0
assert "output without a final newline keeps the failure on its own line" 'has "CHECK partial" && has "CHECK failed: sweep-check exited 3"'

printf '#!/usr/bin/env bash\nsleep 10\n' >"$CREW/sweep-check"
export CREW_SWEEP_CHECK_TIMEOUT=1
sweep 0
assert "a sweep-check past its timeout is stopped and named" '[[ $ELAPSED -lt 5000 ]] && has "CHECK failed: sweep-check timed out after 1 s"'
unset CREW_SWEEP_CHECK_TIMEOUT

printf '#!/usr/bin/env bash\nsleep 10 &\necho started\n' >"$CREW/sweep-check"
sweep 0
assert "a background child holding the check output does not stall the sweep" '[[ $ELAPSED -lt 5000 ]] && has "CHECK started"'

chmod -x "$CREW/sweep-check"
sweep 0
assert "a sweep-check that is not executable is named" 'has "CHECK failed: sweep-check is not executable"'
rm "$CREW/sweep-check"
sweep 0
assert "no sweep-check prints no CHECK line" '! has_re "^CHECK"'

echo "usage and context"
S=$(crew_slug "$REPO")
reset_usage() {
  NOW=$(date +%s)
  HOUR=$((NOW + 3600))
  WEEK=$((NOW + 86400))
  rm -rf "$CREW/items" "$CREW/.sweep-seen" "$CREW/.sweep-limits" "$CREW/.sweep-leftovers"
  mkdir -p "$CREW/items"
  rm -f "$USAGE"/*.json
  tabs
}
reset_usage
printf 'work\nplay\n' >"$FAKE_STATE/profiles"
{ for i in 1 2 3 4 5 6 7; do row "$i" assigned "$S-w$i" "$NOW"; done; } >"$CREW/board.tsv"
usage u1 work 1000 1000000 10 "$HOUR" 10 "$WEEK"
usage u3 work 400000 1000000 10 "$HOUR" 10 "$WEEK"
usage u4 play 170000 200000 10 "$HOUR" 10 "$WEEK"
usage u5 play 399000 null 10 "$HOUR" 10 "$WEEK"
usage u6 play 399000 0 10 "$HOUR" 10 "$WEEK"
usage u7 work null null null null null null
agents "$S-w1 working u1" "$S-w2 working u2" "$S-w3 idle u3" "$S-w4 working u4" \
  "$S-w5 working u5" "$S-w6 working u6" "$S-w7 working u7"
sweep 30
assert "a worker shows the profile of its session" 'has "WORKER $S-w1 item 1 working on work"'
assert "a worker whose session has no usage file is on ?" 'has "WORKER $S-w2 item 2 working on ?"'
assert "CONTEXT at the token threshold comes before IDLE" 'has "WORKER $S-w3 item 3 idle on work CONTEXT 400k IDLE"'
assert "CONTEXT at 80% of a 200k window" 'has "WORKER $S-w4 item 4 working on play CONTEXT 170k"'
assert "a null or 0 context window gives no CONTEXT" 'has "WORKER $S-w5 item 5 working on play" && has "WORKER $S-w6 item 6 working on play"'
assert "null figures give no CONTEXT and no error" 'has "WORKER $S-w7 item 7 working on work" && [[ $RC -eq 0 ]] && ! has_re "^ERROR"'
assert "a new CONTEXT ends the wait at once without TIMEOUT" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT'
assert "a new context alert prints WOKE with the worker's name" 'has "WOKE context $S-w3" && has "WOKE context $S-w4" && ! has "WOKE context $S-w5"'
sweep 1
assert "a CONTEXT already alerted for its session prints without waking" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has "WORKER $S-w4 item 4 working on play CONTEXT 170k"'
assert "an alerted context prints no WOKE" '! has_re "^WOKE"'
usage u3b work 420000 1000000 10 "$HOUR" 10 "$WEEK"
agents "$S-w1 working u1" "$S-w3 working u3b"
{
  row 1 assigned "$S-w1" "$NOW"
  row 3 assigned "$S-w3" "$NOW"
} >"$CREW/board.tsv"
sweep 30
assert "CONTEXT in a new session of the same worker wakes again" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has "WORKER $S-w3 item 3 working on work CONTEXT 420k"'
usage u5b play 150000 null 10 "$HOUR" 10 "$WEEK"
usage u6b play 150000 0 10 "$HOUR" 10 "$WEEK"
agents "$S-w5 working u5b" "$S-w6 working u6b"
{
  row 5 assigned "$S-w5" "$NOW"
  row 6 assigned "$S-w6" "$NOW"
  row 8 open ''
} >"$CREW/board.tsv"
sweep 1
assert "workers with a null or 0 window keep the usual lines and exit 0" '[[ $RC -eq 0 ]] && has TIMEOUT && has "READY 8" && has "WORKER $S-w5 item 5 working on play" && has "WORKER $S-w6 item 6 working on play"'

echo "thresholds file"
reset_usage
printf 'CREW_WORKERS_PER_PROFILE=1\nCREW_SESSION_HARD_PCT=50\nCREW_BOGUS=1\nno equals here\n' >"$CREW/thresholds"
{ row 1 assigned "$S-w1" "$NOW"; } >"$CREW/board.tsv"
usage u1 work 1000 1000000 50 "$HOUR" 10 "$WEEK"
agents "$S-w1 working u1"
sweep 0
assert "the thresholds file sets the cap and FULL" 'has "POOL work 1/1/1 session 50% week 10% FULL"'
assert "the thresholds file sets the hard threshold" 'has "LIMIT work session 50% resets in 60 min"'
assert "only crew-resources names the bad thresholds lines" 'has_re "^RESOURCE failed: .*CREW_BOGUS" && ! grep -E "CREW_BOGUS|no equals" <<<"$OUT" | grep -qv "^RESOURCE failed: "'
rm "$CREW/thresholds"

echo "limits in the wait"
reset_usage
usage u1 work 1000 1000000 10 "$HOUR" 10 "$WEEK"
(sleep 1.5 && usage u1 work 1000 1000000 95 "$HOUR" 10 "$WEEK") &
CREW_RESOURCE_EVERY=1 sweep 30
assert "a hard threshold crossed during the wait ends it without TIMEOUT" '[[ $ELAPSED -lt 10000 ]] && ! has TIMEOUT && has "LIMIT work session 95% resets in 60 min"'
reset_usage
usage u1 work 1000 1000000 95 "$HOUR" 10 "$WEEK"
echo 2 >"$FAKE_STATE/list_fail"
CREW_RESOURCE_EVERY=1 sweep 30
assert "a failing agent list inside the wait skips that round only" '[[ $RC -eq 0 && $ELAPSED -lt 10000 ]] && ! has TIMEOUT && ! has_re "^ERROR" && has "LIMIT work session 95% resets in 60 min"'
rm -f "$FAKE_STATE/list_fail"

echo "pool"
reset_usage
printf 'work\nplay\nidle\nspare\nweekly\n' >"$FAKE_STATE/profiles"
{
  row 1 assigned "$S-w1" "$NOW"
  row 2 assigned "$S-w2" "$NOW"
} >"$CREW/board.tsv"
usage u1 work 1000 1000000 20 "$HOUR" 30 "$WEEK"
usage u2 work 1000 1000000 10 "$HOUR" 10 "$WEEK"
usage uo work 1000 1000000 10 "$HOUR" 10 "$WEEK"
usage ul play 1000 1000000 75 "$HOUR" 10 "$WEEK"
usage un play 1000 1000000 10 "$HOUR" 10 "$WEEK"
usage um spare 1000 1000000 10 "$HOUR" 10 "$WEEK"
usage uw weekly 1000 1000000 10 "$HOUR" 85 "$WEEK"
usage ua default 1000 1000000 40 "$((NOW + 600))" 10 "$WEEK"
usage ub default 1000 1000000 60 "$((NOW + 605))" 10 "$WEEK"
agents "$S-w1 working u1" "$S-w2 working u2" "other-w1 working uo" "$S-lead idle ul" \
  "null working un" "mine idle um" "theirs idle"
CREW_WORKERS_PER_PROFILE=3 sweep 0
assert "POOL counts crew and all agents and is FULL at the cap, counting outside agents" 'has "POOL work 2/3/3 session 20% week 30% FULL"'
assert "POOL is FULL at the session soft threshold" 'has "POOL play 0/2/3 session 75% week 10% FULL"'
assert "POOL is FULL at the week soft threshold" 'has "POOL weekly 0/0/3 session 10% week 85% FULL"'
assert "POOL below the cap and both soft thresholds is not FULL" 'has "POOL spare 0/1/3 session 10% week 10%"'
assert "POOL reads ?% for a profile with no session files" 'has "POOL idle 0/0/3 session ?% week ?%"'
assert "POOL takes the higher of two sessions whose resets differ by seconds" 'has "POOL default 0/0/3 session 60% week 10%"'
assert "POOL lists each claude-profile name and default once" '[[ $(grep -c "^POOL " <<<"$OUT") -eq 6 ]]'

echo "opencode workers"
# pane_usage <pane number> <tokens> writes the file harness-crew-usage.js writes.
pane_usage() {
  printf '{"profile":"opencode","context_tokens":%s,"context_window":null}' "$2" >"$USAGE/pane-wB_p$1.json"
}
reset_usage
printf 'work\n' >"$FAKE_STATE/profiles"
{ for i in 1 2 3 4; do row "$i" assigned "$S-w$i" "$NOW"; done; } >"$CREW/board.tsv"
usage u1 work 300000 1000000 10 "$HOUR" 10 "$WEEK"
pane_usage 2 300000
pane_usage 4 299000
agents "$S-w1 working u1" "$S-w2 working - opencode" "$S-w3 working - opencode" "$S-w4 idle - opencode"
sweep 30
assert "an opencode worker reads its usage by pane and flags CONTEXT at 300k" 'has "WORKER $S-w2 item 2 working on opencode CONTEXT 300k"'
assert "a Claude worker at 300k keeps the 400k threshold" 'has "WORKER $S-w1 item 1 working on work"'
assert "an opencode worker below 300k has no CONTEXT" 'has "WORKER $S-w4 item 4 idle on opencode IDLE"'
assert "an opencode worker with no usage file is on opencode" 'has "WORKER $S-w3 item 3 working on opencode"'
assert "the opencode CONTEXT wakes the sweep once by name" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has "WOKE context $S-w2" && [[ $(grep -c "^WOKE" <<<"$OUT") -eq 1 ]]'
assert "the alert is recorded under the pane key" 'grep -q "^context pane-wB_p2	" "$CREW/.sweep-limits"'
sweep 1
assert "an alerted opencode CONTEXT prints without waking" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && ! has_re "^WOKE" && has "WORKER $S-w2 item 2 working on opencode CONTEXT 300k"'
CREW_OPENCODE_CONTEXT_K=1 sweep 0
assert "CREW_OPENCODE_CONTEXT_K sets the opencode threshold only" 'has "WORKER $S-w4 item 4 idle on opencode CONTEXT 299k IDLE" && has "WORKER $S-w1 item 1 working on work"'
assert "no POOL opencode line without opencode on PATH" '! has_re "^POOL opencode"'
echo '{"anthropic":{"type":"api","key":"k"}}' >"$OPENCODE_AUTH"
PATH="$OPENCODE_BIN:$PATH" sweep 0
assert "POOL opencode with opencode and an auth.json entry counts its agents, last" '[[ $(grep "^POOL " <<<"$OUT" | tail -n 1) == "POOL opencode 3/3/5 api" ]]'
PATH="$OPENCODE_BIN:$PATH" CREW_WORKERS_PER_PROFILE=3 sweep 0
assert "POOL opencode is FULL at the cap" 'has "POOL opencode 3/3/3 api FULL"'
echo '{"openai":{"type":"api","key":"k"}}' >"$OPENCODE_AUTH"
PATH="$OPENCODE_BIN:$PATH" sweep 0
assert "no POOL opencode line without an Anthropic credential" '! has_re "^POOL opencode"'
PATH="$OPENCODE_BIN:$PATH" ANTHROPIC_API_KEY=k sweep 0
assert "ANTHROPIC_API_KEY counts as the credential" 'has "POOL opencode 3/3/5 api"'
rm -f "$OPENCODE_AUTH"

echo "limits"
reset_usage
printf 'work\nplay\n' >"$FAKE_STATE/profiles"
B=$(((EPOCHSECONDS / 300 + 12) * 300))
{ row 1 assigned "$S-w1" "$NOW"; } >"$CREW/board.tsv"
usage u1 work 1000 1000000 92 "$((B - 1))" 10 "$WEEK"
usage ul play 1000 1000000 10 "$HOUR" 10 "$WEEK"
usage uo solo 1000 1000000 99 "$HOUR" 99 "$WEEK"
agents "$S-w1 working u1" "$S-lead idle ul" "other working uo"
sweep 30
assert "a crew profile at the session hard threshold wakes with LIMIT" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has_re "^LIMIT work session 92% resets in [0-9]+ min$"'
assert "a profile with neither crew workers nor the lead gets no LIMIT" '! has_re "^LIMIT solo"'
assert "a new LIMIT prints WOKE before the state lines" 'has "WOKE limit work session" && [[ $(grep -n "^WOKE" <<<"$OUT" | cut -d: -f1) -lt $(grep -n "^LIMIT" <<<"$OUT" | cut -d: -f1) ]]'
LIMIT_REC=$(printf "limit work session\t%s" "$((B - 1))")
assert ".sweep-limits records the raw resets" 'grep -qxF "$LIMIT_REC" "$CREW/.sweep-limits"'
sweep 1
assert "an alerted LIMIT prints without waking" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has_re "^LIMIT work session 92% "'
assert "an alerted LIMIT prints no WOKE" '! has_re "^WOKE"'
usage u1b work 1000 1000000 93 "$((B + 1))" 10 "$WEEK"
sweep 1
assert "a second session's resets seconds away across a 300 s boundary does not wake" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has_re "^LIMIT work session 93% "'
usage u1 work 1000 1000000 92 "$((B - 1))" 96 "$WEEK"
sweep 30
assert "the week window of an alerted profile wakes on its own" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has_re "^LIMIT work week 96% "'
assert "only the new window gets WOKE" 'has "WOKE limit work week" && ! has "WOKE limit work session"'
usage u1 work 1000 1000000 95 "$((B + 18000))" 96 "$WEEK"
sweep 30
assert "a new session window wakes again" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has_re "^LIMIT work session 95% "'
agents "$S-lead idle ul" "other working uo"
: >"$CREW/board.tsv"
usage ul play 1000 1000000 91 "$HOUR" 10 "$WEEK"
sweep 30
assert "the lead's profile gets LIMIT with no workers on it" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has "LIMIT play session 91% resets in 60 min" && ! has_re "^LIMIT work"'
{ row 1 assigned "$S-w1" "$NOW"; } >"$CREW/board.tsv"
agents "$S-w1 working ul"
usage ul play 1000 1000000 91 "$HOUR" 97 "$WEEK"
echo 1 >"$FAKE_STATE/list_ok"
sweep 30
rm "$FAKE_STATE/list_ok"
sweep 1
assert "a LIMIT is recorded even when the sweep then exits on a herdr failure" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has_re "^LIMIT play week 97% "'

echo "spare"
reset_usage
printf 'work\n' >"$FAKE_STATE/profiles"
{
  row 1 assigned "$S-w1" "$NOW"
  row 2 blocked "$S-w3" "$NOW"
  row 3 assigned "$S-w4" "$NOW"
} >"$CREW/board.tsv"
for u in u1 u2 u3 uo ul; do usage "$u" work 1000 1000000 10 "$HOUR" 10 "$WEEK"; done
usage u5 work 450000 1000000 10 "$HOUR" 10 "$WEEK"
agents "$S-w1 working u1" "$S-w2 idle u2" "$S-w3 idle u3" "$S-w5 idle u5" "$S-old1 idle uo" "$S-lead idle ul"
tabs "$S-w1" "$S-w2" "$S-w3" "$S-w4" "$S-w6" "$S-old1" "$S-lead"
sweep 0
assert "an unassigned live worker is SPARE" 'has "SPARE $S-w2 idle on work"'
assert "a SPARE that owns a blocked row holds it" 'has "SPARE $S-w3 idle on work holds 2"'
assert "a SPARE over the context threshold has CONTEXT" 'has "SPARE $S-w5 idle on work CONTEXT 450k"'
assert "a worker tab with no agent is SPARE no agent" 'has "SPARE $S-w6 no agent"'
assert "no SPARE for an assigned worker, an old lead, the lead or a GONE owner's tab" '! has_re "^SPARE ($S-w1|$S-old1|$S-lead|$S-w4) " && has "GONE $S-w4"'

echo "leftovers"
reset_usage
tree=$(gc mktree </dev/null)
base=$(gc commit-tree -m base "$tree")
for i in 21 22 24 25 26 27 28 30; do
  gc update-ref "refs/heads/w/$i" "$(gc commit-tree -p "$base" -m "item $i" "$tree")"
done
gc update-ref refs/heads/trunk "$(gc commit-tree -p "$base" -p w/21 -p w/22 -p w/24 -p w/27 -p w/28 -p w/30 -m land "$tree")"
gc update-ref refs/heads/w/31 trunk
gc update-ref refs/heads/w/32 trunk
merged() {
  mkdir -p "$CREW/items/$1"
  printf 'branch w/%s\ntip %s\nmerged %s\ninto trunk\n' "$1" "$(gc rev-parse "${2:-w/$1}")" "$(gc rev-parse trunk)" >"$CREW/items/$1/merged"
}
for i in 21 22 24 26 27 28 30; do merged "$i"; done
merged 23 trunk
gc worktree add -q "$REPO/.claude/worktrees/w-21" w/21
mkdir -p "$TMP_DIR/build/w-23"
echo "$TMP_DIR/build/w-23" >"$CREW/items/23/build-dir"
touch -d "@$((NOW - 100))" "$CREW/items/27/merged" "$CREW/items/30/merged"
echo "status: done" >"$CREW/items/27/report.md"
touch -d "@$((NOW - 200))" "$CREW/items/27/report.md"
echo "status: done" >"$CREW/items/30/report.md"
mkdir -p "$CREW/items/25"
echo "status: done" >"$CREW/items/25/report.md"
mkdir -p "$CREW/items/31" "$CREW/items/32" "$TMP_DIR/build/w-31"
touch "$CREW/items/31/report-only" "$CREW/items/32/report-only"
gc worktree add -q "$REPO/.claude/worktrees/w-31" w/31
echo "$TMP_DIR/build/w-31" >"$CREW/items/31/build-dir"
echo "status: done" >"$CREW/items/31/report.md"
echo "status: question" >"$CREW/items/32/report.md"
leftover_rows() {
  row 21 done "$S-w1" "$NOW"
  row 22 done "$S-w2" "$NOW"
  row 23 done "$S-w2" "$NOW"
  row 24 blocked "$S-w2" "$NOW"
  row 25 done "$S-w2" "$NOW"
  row 26 done "$S-w2" "$NOW"
  row 27 done "$S-w7" "$NOW"
  row 28 done "$S-w8" "$NOW"
  row 29 "$1" "$S-w8" "$NOW"
  row 30 done "$S-w3" "$NOW"
  row 31 done "$S-w7" "$NOW"
  row 32 done "$S-w3" "$NOW"
}
leftover_rows assigned >"$CREW/board.tsv"
agents "$S-w7 idle" "$S-w8 working" "$S-w3 idle"
sweep 0
assert "a merged done row's worktree is LEFTOVER" 'has "LEFTOVER 21 worktree $REPO/.claude/worktrees/w-21"'
assert "a merged done row's branch is LEFTOVER" 'has "LEFTOVER 21 branch w/21" && has "LEFTOVER 22 branch w/22"'
assert "a merged done row's build dir is LEFTOVER" 'has "LEFTOVER 23 build-dir $TMP_DIR/build/w-23"'
assert "a blocked row with a merged file gets LEFTOVER" 'has "LEFTOVER 24 branch w/24"'
assert "a worker given another item has finished landing" 'has "LEFTOVER 28 branch w/28"'
assert "a done report newer than the merged file finishes landing" 'has "LEFTOVER 30 branch w/30"'
assert "no LEFTOVER for an unmerged row or a tip outside into" '! has_re "^LEFTOVER (25|26) "'
assert "no LEFTOVER while a live owner has not reported after the merge" '! has_re "^LEFTOVER 27 "'
assert "a report-only item with a done report gets LEFTOVER with no merged file" 'has "LEFTOVER 31 worktree $REPO/.claude/worktrees/w-31" && has "LEFTOVER 31 branch w/31" && has "LEFTOVER 31 build-dir $TMP_DIR/build/w-31"'
assert "no LEFTOVER for a report-only item whose report is not done" '! has_re "^LEFTOVER 32 "'
assert "each LEFTOVER line is counted once" '[[ $(grep -c "^LEFTOVER " <<<"$OUT") -eq 10 ]]'
sweep 0
assert "a LEFTOVER prints once" '! has_re "^LEFTOVER "'
rm -f "$CREW/.sweep-leftovers"
leftover_rows done >"$CREW/board.tsv"
agents "$S-w7 idle" "$S-w8 idle" "$S-w3 idle"
sweep 0
assert "with every row done, SPARE and LEFTOVER print before ALL-DONE" '[[ $RC -eq 0 ]] && has "SPARE $S-w8 idle on ?" && has "LEFTOVER 22 branch w/22" && has "POOL work 0/0/5 session ?% week ?%" && [[ $(tail -n 1 <<<"$OUT") == ALL-DONE ]]'
echo 1000 >"$FAKE_STATE/list_fail"
sweep 0
assert "a failing agent list still gives ALL-DONE with exit 0" '[[ $RC -eq 0 && $OUT == ALL-DONE ]]'
rm "$FAKE_STATE/list_fail"
gc worktree remove --force "$REPO/.claude/worktrees/w-21"

echo "handoff"
reset_usage
OLD=$(($(date +%s) - 1000))
{ row 1 assigned "$S-w1" "$OLD"; } >"$CREW/board.tsv"
mkdir -p "$CREW/items/1"
echo "status: handoff" >"$CREW/items/1/report.md"
touch -d "@$((OLD + 10))" "$CREW/items/1/report.md"
agents "$S-w1 working"
CREW_QUIET=100 sweep 0
assert "a handoff report is never QUIET" 'has "WORKER $S-w1 item 1 working on ?"'
rm -rf "$CREW/items" "$CREW/.sweep-seen" "$CREW/.sweep-limits" "$CREW/.sweep-leftovers"
mkdir -p "$CREW/items"
rm -f "$USAGE"/*.json
: >"$FAKE_STATE/profiles"
{ row 1 open ''; } >"$CREW/board.tsv"
agents

HQ="$CREW/heavy.queue"
LW="$CREW/light.wait"
TICKET=
ticket() {
  local dir=$1 holder=$2 age=${3:-0} pid now
  sleep 300 &
  pid=$!
  PIDS+=("$pid")
  now=$(date +%s)
  TZ=UTC0 date -d "@$((now - age - 60))" '+%a %b %e %H:%M:%S %Y' >"$FAKE_STATE/ps-start-$pid"
  mkdir -p "$dir"
  printf -v TICKET '%s/%020d.%s.%s' "$dir" "$(((now - age) * 1000000))" "$pid" "$holder"
  : >"$TICKET"
}

echo "heavy slot"
HLOCK="$CREW/heavy.lock"
mkdir "$HLOCK"
printf '7\tbrowser check\t%s\n' "$(($(date +%s) - 100 * 60))" >"$HLOCK/holder"
ticket "$HQ" w9
sweep 0
assert "without heavy-slots a long-held slot prints no HEAVY line" '! has_re "^HEAVY"'
echo 1 >"$CREW/heavy-slots"
sweep 0
assert "a slot held past 90 minutes with a waiter prints HEAVY with holder, minutes and purpose" 'has "HEAVY 7 100 min browser check"'
rm "$TICKET"
sweep 0
assert "a slot held past 90 minutes with no waiter prints no HEAVY line" '! has_re "^HEAVY"'
ticket "$HQ" w9
printf '7\tbrowser check\t%s\n' "$(($(date +%s) - 80 * 60))" >"$HLOCK/holder"
sweep 0
assert "a slot held under 90 minutes prints no HEAVY line" '! has_re "^HEAVY"'
rm "$HLOCK/holder"
touch -d "@$(($(date +%s) - 95 * 60))" "$HLOCK"
sweep 0
assert "a slot with no holder file is aged by the lock dir" 'has "HEAVY unknown 95 min unknown"'
assert "a slot with no holder file prints no error" '! has_re "No such file"'
rmdir "$HLOCK"
sweep 0
assert "a free slot prints no HEAVY line" '! has_re "^HEAVY"'
rm -rf "$HQ"
echo 2 >"$CREW/heavy-slots"
sweep 0
assert "a heavy-slots file other than 1 is named" 'has "HEAVY failed: heavy-slots must contain 1" && [[ $RC -eq 0 ]]'
rm "$CREW/heavy-slots"

echo "heavy queue"
export CREW_QUIET=100
NOW=$(date +%s)
OLD=$((NOW - 1000))
rm -rf "$CREW/items" "$CREW/.sweep-seen"
mkdir -p "$CREW/items"/{1..9}
sleep 300 &
LIVE=$!
PIDS+=("$LIVE")
live_start=$(crew_pid_start "$LIVE")
for i in 2 3; do
  printf 'pid %s\nstart %s\ntip %040d\n' "$LIVE" "$live_start" 0 >"$CREW/items/$i/merging"
  touch -d "@$OLD" "$CREW/items/$i/merging"
done
printf 'pid %s\nstart 1\ntip %040d\n' "$LIVE" 0 >"$CREW/items/7/merging"
touch -d "@$OLD" "$CREW/items/7/merging"
for i in 8:2 9:3; do
  printf 'pid %s\nstart %s\ntip %040d\nticket 1\nowner 1 1\nleader %s\n' "$LIVE" "$live_start" 0 "${i#*:}" >"$CREW/items/${i%:*}/merging"
  touch -d "@$OLD" "$CREW/items/${i%:*}/merging"
done
{ for i in 1 2 3 4 5 6 7 8 9; do row "$i" assigned "x-w$i" "$OLD"; done; } >"$CREW/board.tsv"
agents 'x-w1 idle' 'x-w2 working' 'x-w3 working' 'x-w4 idle' 'x-w5 idle' 'x-w6 idle' 'x-w7 idle' 'x-w8 working' 'x-w9 working'
ticket "$HQ" 1 450
ticket "$HQ" merge-2 200
ticket "$LW" 5
sleep 300 &
PIDS+=("$!")
: >"$(printf '%s/%020d.%s.%s' "$LW" "$(((NOW - 600) * 1000000))" "$!" 6)"
sweep 0
assert "an item id in the heavy queue is HEAVY-WAIT with its minutes, never IDLE or QUIET" 'has "WORKER x-w1 item 1 idle on ? HEAVY-WAIT 7m"'
assert "a running merge whose merge id queues is HEAVY-WAIT, not QUIET for an old merging file" 'has "WORKER x-w2 item 2 working on ? MERGING HEAVY-WAIT 3m"'
assert "an item batched by a leader whose merge id queues is HEAVY-WAIT, not QUIET" 'has "WORKER x-w8 item 8 working on ? MERGING HEAVY-WAIT 3m"'
assert "a live light.wait ticket is LIGHT-WAIT, never IDLE or QUIET" 'has "WORKER x-w5 item 5 idle on ? LIGHT-WAIT"'
assert "a light.wait ticket whose pid was reused is ignored" 'has "WORKER x-w6 item 6 idle on ? IDLE QUIET"'
assert "a worker outside both queues keeps IDLE QUIET" 'has "WORKER x-w4 item 4 idle on ? IDLE QUIET"'
rm -rf "$HQ" "$LW"
mkdir "$HLOCK"
printf 'merge-3\tgate\t%s\n' "$((NOW - 10))" >"$HLOCK/holder"
sweep 0
assert "a running merge holding the slot is HEAVY-HOLD, QUIET measured from the hold" 'has "WORKER x-w3 item 3 working on ? MERGING HEAVY-HOLD"'
assert "an item batched by the leader holding the slot measures QUIET from the hold" 'has "WORKER x-w9 item 9 working on ? MERGING"'
printf 'merge-3\tgate\t%s\n' "$((NOW - 200))" >"$HLOCK/holder"
sweep 0
assert "a merge hold older than CREW_QUIET is QUIET" 'has "WORKER x-w3 item 3 working on ? MERGING HEAVY-HOLD QUIET"'
assert "an item batched by a leader with an old hold is QUIET" 'has "WORKER x-w9 item 9 working on ? MERGING QUIET"'
printf '4\tbrowser\t%s\n' "$((NOW - 2000))" >"$HLOCK/holder"
sweep 0
assert "an idle item-id holder is IDLE HEAVY-HOLD, not QUIET before CREW_HEAVY_LONG" 'has "WORKER x-w4 item 4 idle on ? IDLE HEAVY-HOLD"'
CREW_HEAVY_LONG=500 sweep 0
assert "an item-id holder with no progress past CREW_HEAVY_LONG is QUIET" 'has "WORKER x-w4 item 4 idle on ? IDLE HEAVY-HOLD QUIET"'
printf '4\tbrowser\t%s\n' "$((NOW - 10))" >"$HLOCK/holder"
CREW_HEAVY_LONG=500 sweep 0
assert "an item-id hold newer than the last progress counts as progress" 'has "WORKER x-w4 item 4 idle on ? IDLE HEAVY-HOLD"'
printf 'merge-7\tgate\t%s\n' "$((NOW - 10))" >"$HLOCK/holder"
sweep 0
assert "a merge hold under a stale merging marker is neither MERGING nor HEAVY-HOLD" 'has "WORKER x-w7 item 7 idle on ? IDLE QUIET"'
echo 1 >"$CREW/heavy-slots"
printf 'merge-3\tgate\t%s\n' "$((NOW - 100 * 60))" >"$HLOCK/holder"
sweep 0
assert "a long running merge hold with no waiter prints no HEAVY line" '! has_re "^HEAVY"'
ticket "$LW" 5
sweep 0
assert "a live light ticket makes a long running merge hold print HEAVY" 'has "HEAVY merge-3 100 min gate"'
printf '4\tbrowser\t%s\n' "$((NOW - 100 * 60))" >"$HLOCK/holder"
sweep 0
assert "a live light ticket does not make a long item-id hold print HEAVY" '! has_re "^HEAVY"'
ticket "$HQ" 6
sweep 0
assert "a heavy waiter makes a long item-id hold print HEAVY" 'has "HEAVY 4 100 min browser"'
rm -rf "$HQ" "$LW" "$HLOCK" "$CREW/heavy-slots" "$CREW/items" "$CREW/.sweep-seen"
mkdir -p "$CREW/items"
kill "$LIVE" 2>/dev/null || true
wait "$LIVE" 2>/dev/null || true
export CREW_QUIET=1000000
{ row 1 open ''; } >"$CREW/board.tsv"
agents
echo "resources"
rm -rf "$CREW/items" "$CREW/.sweep-seen" "$CREW/.sweep-resources"
mkdir -p "$CREW/items"
{ row 1 open ''; } >"$CREW/board.tsv"
agents
CREW_MEM_MIN_MB=999999999 sweep 30
assert "a breach on a first sweep ends the wait at once without TIMEOUT" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has_re "^RESOURCE memory [0-9]+ MB available$"'
assert ".sweep-resources records each key with when it was alerted" 'grep -qE "^memory	[0-9]+$" "$CREW/.sweep-resources"'
CREW_MEM_MIN_MB=999999999 sweep 2
assert "a breach alerted within the hold waits out the wait and is still printed" '[[ $ELAPSED -ge 2000 ]] && has TIMEOUT && has_re "^RESOURCE memory "'
sweep 0
assert "a cleared breach prints no RESOURCE line" '! has_re "^RESOURCE"'
CREW_MEM_MIN_MB=999999999 sweep 2
assert "a breach that clears and returns within the hold does not end the wait" '[[ $ELAPSED -ge 2000 ]] && has TIMEOUT'
sleep 1
CREW_MEM_MIN_MB=999999999 CREW_RESOURCE_HOLD=1 sweep 30
assert "a breach that persists past the hold ends the wait again" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT'
CREW_DISK_MIN_GB=999999 sweep 0
assert "a disk under its threshold prints a RESOURCE disk line" 'has_re "^RESOURCE disk .+ [0-9]+ GB free, critical \(.+\)$"'
printf 'gone\t1\n' >>"$CREW/.sweep-resources"
sweep 0
assert "records older than the hold are dropped" '! grep -q "^gone" "$CREW/.sweep-resources"'

REAL_SWEEP=$SWEEP
mkdir -p "$TMP_DIR/sweepcopy"
cp "$SWEEP" "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh" "$TMP_DIR/sweepcopy/"
SWEEP="$TMP_DIR/sweepcopy/crew-sweep"
# Fake crew-resources beside the copied sweep: prints $FAKE_STATE/resources,
# and with resources_err present writes that to stderr and exits 1.
cat >"$TMP_DIR/sweepcopy/crew-resources" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_STATE/resources" 2>/dev/null
if [[ -f $FAKE_STATE/resources_err ]]; then
  cat "$FAKE_STATE/resources_err" >&2
  exit 1
fi
EOF
chmod +x "$TMP_DIR/sweepcopy/crew-resources"
rm -f "$CREW/.sweep-resources"
: >"$FAKE_STATE/resources"
(sleep 1.5 && echo "memory 10 MB available" >"$FAKE_STATE/resources.tmp" && mv "$FAKE_STATE/resources.tmp" "$FAKE_STATE/resources") &
CREW_RESOURCE_EVERY=1 sweep 10
assert "a breach that starts during the wait ends it" '[[ $ELAPSED -lt 5000 ]] && ! has TIMEOUT && has "RESOURCE memory 10 MB available"'
echo "disk /Volumes/My Disk 9 GB free (/w)" >"$FAKE_STATE/resources"
sweep 0
sweep 1
assert "a low disk alerted within the hold does not end the wait" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has "RESOURCE disk /Volumes/My Disk 9 GB free (/w)"'
echo "disk /Volumes/My Disk 3 GB free, critical (/w)" >"$FAKE_STATE/resources"
sweep 10
assert "a disk falling to critical ends the wait at once" '[[ $ELAPSED -lt 3000 ]] && ! has TIMEOUT && has "RESOURCE disk /Volumes/My Disk 3 GB free, critical (/w)"'
echo "disk /Volumes/My Disk 6 GB free (/w)" >"$FAKE_STATE/resources"
sweep 1
assert "a critical disk recovering to low within the hold does not end the wait" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT'
: >"$FAKE_STATE/resources"
echo "crew-resources: df /x: Stale file handle" >"$FAKE_STATE/resources_err"
sweep 1
assert "a failing crew-resources prints RESOURCE failed and never ends the wait" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has "RESOURCE failed: df /x: Stale file handle"'
rm "$FAKE_STATE/resources_err"
echo "io 45.20% full over 60 s (D state: cargo x3, kworker)" >"$FAKE_STATE/resources"
sweep 10
assert "a new io breach ends the wait" '[[ $ELAPSED -lt 3000 ]] && ! has TIMEOUT && has "RESOURCE io 45.20% full over 60 s (D state: cargo x3, kworker)"'
echo "io 51.00% full over 60 s (D state: none seen)" >"$FAKE_STATE/resources"
sweep 1
assert "an io breach alerted within the hold does not end the wait" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has_re "^RESOURCE io 51.00% "'
echo "load 99 over 1 CPUs" >"$FAKE_STATE/resources"
{ row 1 assigned x-w1 "$(date +%s)"; } >"$CREW/board.tsv"
echo 1000 >"$FAKE_STATE/list_fail"
sweep 5
rm "$FAKE_STATE/list_fail"
agents 'x-w1 working'
sweep 1
assert "an alert is recorded even when the sweep then exits on a herdr failure" '[[ $ELAPSED -ge 1000 ]] && has TIMEOUT && has "RESOURCE load 99 over 1 CPUs"'
: >"$FAKE_STATE/resources"
{ row 1 open ''; } >"$CREW/board.tsv"
agents
SWEEP=$REAL_SWEEP
rm -f "$CREW/.sweep-resources"

echo "worker role"
set_role worker
sweep 0
assert "a worker running the sweep gets an error, not SUPERSEDED" '[[ $RC -ne 0 ]] && ! has SUPERSEDED'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
