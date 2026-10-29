#!/usr/bin/env bash
set -euo pipefail

REAL_DAGR=
if root=$(timeout 10 herdr plugin list --json 2>/dev/null |
  jq -er '.result.plugins[]? | select(.plugin_id == "herdr-dagr") | .plugin_root' 2>/dev/null); then
  [[ -x $root/bin/dagr ]] && REAL_DAGR=$root/bin/dagr
fi

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH DAGR_BIN
while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_CONFIG_' || true)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CREW_DAGR="$REPO_ROOT/configs/claude-code/bin/crew-dagr"

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
trap 'command rm -rf "$TMP_DIR"' EXIT

export FAKE_STATE="$TMP_DIR/state"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_STATE" "$FAKE_BIN"

clean_path=
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [[ -n $d && ! -x $d/dagr ]] && clean_path+=":$d"
done
export PATH="$FAKE_BIN$clean_path"

# Fake herdr: `agent list` prints agents.json (failing while list_fail exists),
# `pane list` prints panes.json and `plugin list --json` prints plugins.json.
cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_STATE
case "$1 $2" in
"agent list")
  if [[ -f $d/list_fail ]]; then
    echo "herdr: cannot reach server socket" >&2
    exit 1
  fi
  cat "$d/agents.json"
  ;;
"pane list") cat "$d/panes.json" ;;
"plugin list") cat "$d/plugins.json" ;;
*)
  echo "fake herdr: unexpected $*" >&2
  exit 2
  ;;
esac
EOF

# Fake validator: records its arguments and prints no findings, or one error
# while check_fail exists.
FAKE_DAGR="$TMP_DIR/plugin/bin/dagr"
mkdir -p "${FAKE_DAGR%/*}"
cat >"$FAKE_DAGR" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/dagr_calls"
if [[ -f $FAKE_STATE/check_fail ]]; then
  echo '[{"level":"error","code":"E150","path":"tasks[0]","msg":"task 1 contradicts its attempts"}]'
  exit 1
fi
echo '[]'
EOF
chmod +x "$FAKE_BIN/herdr" "$FAKE_DAGR"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
REPO=$(cd "$REPO" && pwd -P)
CREW="$REPO/.claude/crew"
mkdir -p "$CREW/items" "$REPO/sub"
RUN="$REPO/.dagr/run.json"

# agents 'name pane' ...
agents() {
  local a
  for a in "$@"; do
    jq -n --arg n "${a% *}" --arg p "${a##* }" \
      '{name: $n, pane_id: $p, agent_status: "working", agent_session: {value: "s-\($p)"}}'
  done | jq -s '{result: {agents: .}}' >"$FAKE_STATE/agents.json"
}

lead_cwd() {
  jq -n --arg c "$1" '{result: {panes: [{pane_id: "wB:p9", cwd: "/elsewhere"}, {pane_id: "wB:p0", cwd: $c}]}}' \
    >"$FAKE_STATE/panes.json"
}

plugins() {
  if [[ -n ${1:-} ]]; then
    jq -n --arg r "$1" '{result: {plugins: [{plugin_id: "herdr-other", plugin_root: "/nonexistent"}, {plugin_id: "herdr-dagr", plugin_root: $r}]}}'
  else
    jq -n '{result: {plugins: [{plugin_id: "herdr-other", plugin_root: "/nonexistent"}]}}'
  fi >"$FAKE_STATE/plugins.json"
}

# row id status owner updated [deliverable]
row() {
  printf '%s\t%s\t%s\tw/%s\tmain\t%s\t%s\n' "$1" "$2" "$3" "$1" "$4" "${5-deliver item $1}"
}

# report id status mtime
report() {
  mkdir -p "$CREW/items/$1"
  printf 'status: %s\nsummary\n' "$2" >"$CREW/items/$1/report.md"
  touch -d "@$3" "$CREW/items/$1/report.md"
}

merged() {
  mkdir -p "$CREW/items/$1"
  printf 'branch w/%s\ntip %040d\nmerged %s\ninto main\n' "$1" 0 "$2" >"$CREW/items/$1/merged"
}

RC=0
OUT=
run_dagr() {
  RC=0
  OUT=$(cd "$REPO/sub" && "$CREW_DAGR" 2>&1) || RC=$?
}

task() { jq -c --arg id "$1" '.tasks[] | select(.id == $id)' "${2:-$RUN}"; }
tq() { jq -r --arg id "$1" ".tasks[] | select(.id == \$id) | $2" "$RUN"; }

real_check() {
  [[ -n $REAL_DAGR ]] || return 0
  local findings
  findings=$("$REAL_DAGR" check "$1" --json 2>&1) || true
  jq -r '.[] | select(.level == "warning") | "        warning \(.code) \(.path): \(.msg)"' <<<"$findings" 2>/dev/null || true
  OUT=$findings
  jq -e '[.[] | select(.level == "error")] | length == 0' <<<"$findings" >/dev/null 2>&1
}

NOW=$(date +%s)
printf 'wB:p0\tsess-lead\n' >"$CREW/lead"
lead_cwd "$REPO"
plugins
agents

echo "validator lookup"
{ row 1 assigned x-w1 $((NOW - 100)); } >"$CREW/board.tsv"
agents 'x-w1 wB:p1'
run_dagr
assert "no validator exits 0 silently" '[[ $RC -eq 0 && -z $OUT ]]'
assert "no validator writes nothing" '[[ ! -e $REPO/.dagr && ! -e $REPO/sub/.dagr && ! -e $CREW/items/1/attempts && ! -e $CREW/dagr-run ]]'

plugins "$TMP_DIR/plugin"
run_dagr
assert "the herdr-dagr plugin root supplies the validator" '[[ $RC -eq 0 && -f $RUN ]] && grep -q -- "--json" "$FAKE_STATE/dagr_calls"'
rm -rf "$REPO/.dagr" "$FAKE_STATE/dagr_calls"

plugins
export DAGR_BIN="$FAKE_DAGR"
run_dagr
assert "DAGR_BIN supplies the validator" '[[ $RC -eq 0 && -f $RUN && -s $FAKE_STATE/dagr_calls ]]'

echo "row and report states"
rm -rf "$CREW/items" "$CREW/dagr-run" "$REPO/.dagr"
mkdir -p "$CREW/items"
U=$((NOW - 100))
{
  row 1 open '' "$U"
  row 2 assigned x-w2 "$U"
  row 3 assigned x-w3 "$U"
  row 4 assigned x-w4 "$U"
  row 5 assigned x-w5 "$U"
  row 6 assigned x-w6 "$U"
  row 7 assigned x-w7 "$U"
  row 8 assigned x-w8 "$U"
  row 9 done x-w9 "$U"
  row 10 blocked x-w10 "$U"
  row 11 assigned x-w11 "$U" ''
  row 12 done '' "$U"
  printf '13\tfinished\tx-w13\tw/13\tmain\t0\tx\n'
  printf '\n'
} >"$CREW/board.tsv"
report 3 done $((NOW - 50))
merged 3 abcdef0123456789abcdef0123456789abcdef01
report 4 done $((U - 50))
report 5 question $((NOW - 50))
report 6 blocked $((NOW - 50))
report 7 rate-limited $((NOW - 50))
merged 9 1111111111111111111111111111111111111111
agents 'x-w2 wB:p2' 'x-w3 wB:p3' 'x-w4 wB:p4' 'x-w5 wB:p5' 'x-w6 wB:p6' 'x-w7 wB:p7' 'x-w11 wB:p11' 'x-lead wB:p0'
run_dagr
assert "a valid crew publishes and exits 0" '[[ $RC -eq 0 && -f $RUN ]]'
assert "the document is version 3 with the lead as orchestrator" '[[ $(jq -r ".dagr, .run.orchestrator.pane" "$RUN" | tr "\n" " ") == "3 wB:p0 " ]]'
assert "the run is titled after the repo" '[[ $(jq -r .run.title "$RUN") == "crew repo" ]]'
assert "generated_at is set" 'jq -e ".generated_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\")" "$RUN" >/dev/null'
assert "rows with an unknown status or blank lines are skipped" '[[ $(jq ".tasks | length" "$RUN") -eq 12 ]]'
assert "every task is an impl" '[[ $(jq "[.tasks[] | select(.kind != \"impl\")] | length" "$RUN") -eq 0 ]]'
assert "open is queued with no attempts" '[[ $(tq 1 ".state, (.attempts | length)" | tr "\n" " ") == "queued 0 " ]]'
assert "an empty owner keeps the later columns in place" '[[ $(tq 1 ".title, .owner") == $'"'"'deliver item 1\nnull'"'"' ]]'
assert "assigned with no report is working" '[[ $(tq 2 ".state, .attempts[0].state" | tr "\n" " ") == "working working " ]]'
assert "a working attempt has the agent pane as locator" '[[ $(tq 2 ".attempts[0].locator.pane, .attempts[0].locator.agent" | tr "\n" " ") == "wB:p2 x-w2 " ]]'
assert "a working attempt has liveness facts" '[[ $(tq 2 ".attempts[0].liveness | [.prompt_acknowledged, .queued_input] | @tsv") == $'"'"'true\t0'"'"' ]]'
assert "a first attempt counts a report older than the row update" '[[ $(tq 4 .state) == done ]]'
assert "the first attempt starts at the row update" '[[ $(tq 2 ".attempts[0].started_at") == $(date -u -d "@$U" +%FT%TZ) ]]'
assert "done with merged is verified with a receipt" '[[ $(tq 3 ".state, .attempts[0].state, .attempts[0].outcome.evidence, .attempts[0].outcome.receipt" | tr "\n" "|") == "done|done|verified|merged abcdef012345 into main|" ]]'
assert "done without merged is reported" '[[ $(tq 4 ".state, .attempts[0].outcome.evidence" | tr "\n" " ") == "done reported " ]]'
assert "question is blocked on the lead with a working attempt" '[[ $(tq 5 ".state, .unblock, .attempts[0].state" | tr "\n" " ") == "blocked lead working " ]]'
assert "a blocked report is blocked on the lead" '[[ $(tq 6 ".state, .unblock" | tr "\n" " ") == "blocked lead " ]]'
assert "rate-limited loses the attempt and blocks on the lead" '[[ $(tq 7 ".state, .unblock, .attempts[0].state" | tr "\n" " ") == "blocked lead lost " ]]'
assert "an owner herdr does not list loses the attempt" '[[ $(tq 8 ".state, .unblock, .attempts[0].state" | tr "\n" " ") == "blocked lead lost " ]]'
assert "a done row is done and verified by its merge" '[[ $(tq 9 ".state, .attempts[0].state, .attempts[0].outcome.evidence" | tr "\n" " ") == "done done verified " ]]'
assert "a blocked row waits on the user" '[[ $(tq 10 ".state, .unblock, .attempts[0].state" | tr "\n" " ") == "blocked user lost " ]]'
assert "an empty deliverable gets a title" '[[ $(tq 11 .title) == "item 11" && $(tq 2 .title) == "deliver item 2" ]]'
assert "a done row without an owner still has a done attempt" '[[ $(tq 12 ".state, .attempts[0].state, .attempts[0].outcome.evidence" | tr "\n" " ") == "done done reported " ]]'
assert "the owner is the task owner and the attempt actor" '[[ $(tq 5 ".owner, .attempts[0].actor" | tr "\n" " ") == "x-w5 x-w5 " ]]'
assert "attempt ids follow the task·aN style" '[[ $(tq 5 ".attempts[0].id, .attempts[0].n, .attempts[0].cause.type" | tr "\n" " ") == "5·a1 1 initial " ]]'
assert "the real dagr check finds no errors" 'real_check "$RUN"'

echo "replacement"
run_id=$(jq -r .run.id "$RUN")
started=$(jq -r .run.started_at "$RUN")
report 2 rate-limited $((NOW - 10))
{ row 2 assigned x-w2b "$NOW"; } >"$CREW/board.tsv"
agents 'x-w2b wB:p12'
run_dagr
assert "the run id and start persist across writes" '[[ $(jq -r .run.id "$RUN") == "$run_id" && $(jq -r .run.started_at "$RUN") == "$started" ]]'
assert "a replaced owner adds a second attempt" '[[ $(tq 2 ".attempts | length") -eq 2 ]]'
assert "the first attempt is lost" '[[ $(tq 2 ".attempts[0].state, .attempts[0].actor" | tr "\n" " ") == "lost x-w2 " ]]'
assert "the second attempt supersedes the first" '[[ $(tq 2 ".attempts[1].n, .attempts[1].cause.type, .attempts[1].cause.ref, .attempts[1].actor" | tr "\n" " ") == "2 superseded 2·a1 x-w2b " ]]'
assert "an old rate-limited report does not mark the new worker lost" '[[ $(tq 2 ".state, .attempts[1].state" | tr "\n" " ") == "working working " ]]'
assert "the lost attempt ends when the next starts" '[[ $(tq 2 ".attempts[0].ended_at") == $(tq 2 ".attempts[1].started_at") ]]'
assert "a replacement starts at the bumped row update" '[[ $(tq 2 ".attempts[1].started_at") == $(date -u -d "@$NOW" +%FT%TZ) ]]'
run_dagr
assert "an unchanged owner adds no attempt" '[[ $(wc -l <"$CREW/items/2/attempts") -eq 2 ]]'
report 2 done $((NOW + 30))
merged 2 2222222222222222222222222222222222222222
run_dagr
assert "the new worker's report counts" '[[ $(tq 2 ".state, .attempts[1].state, .attempts[0].state" | tr "\n" " ") == "done done lost " ]]'
assert "the real dagr check finds no errors after a replacement" 'real_check "$RUN"'

{ row 5 assigned x-w5b "$U"; } >"$CREW/board.tsv"
agents 'x-w5b wB:p13'
run_dagr
assert "a replacement without a row update starts at first sight" '[[ $(date -d "$(tq 5 ".attempts[1].started_at")" +%s) -ge $NOW ]]'
assert "so the predecessor's question does not block it" '[[ $(tq 5 ".state, .attempts[1].state" | tr "\n" " ") == "working working " ]]'

echo "failures"
cp "$RUN" "$TMP_DIR/before.json"
touch "$FAKE_STATE/check_fail"
{
  row 2 assigned x-w2b "$NOW"
  row 3 open '' "$NOW"
} >"$CREW/board.tsv"
run_dagr
assert "a failed check exits non-zero" '[[ $RC -ne 0 ]]'
assert "a failed check keeps the previous file" 'cmp -s "$RUN" "$TMP_DIR/before.json"'
assert "a failed check leaves no temporary file" '[[ $(ls -A "$REPO/.dagr") == run.json ]]'
assert "a failed check is logged" 'grep -q E150 "$CREW/dagr.log"'
rm "$FAKE_STATE/check_fail"

touch "$FAKE_STATE/list_fail"
run_dagr
assert "a failing agent list publishes nothing" '[[ $RC -ne 0 ]] && cmp -s "$RUN" "$TMP_DIR/before.json"'
rm "$FAKE_STATE/list_fail"

mv "$CREW/lead" "$TMP_DIR/lead"
: >"$FAKE_STATE/dagr_calls"
run_dagr
assert "no lead file writes nothing" '[[ $RC -eq 0 && ! -s $FAKE_STATE/dagr_calls ]] && cmp -s "$RUN" "$TMP_DIR/before.json"'
mv "$TMP_DIR/lead" "$CREW/lead"

echo "target directory"
rm -rf "$REPO/.dagr"
lead_cwd "$REPO/sub"
run_dagr
assert "a lead cwd inside the repo gets the file" '[[ -f $REPO/sub/.dagr/run.json && ! -e $REPO/.dagr ]]'
rm -rf "$REPO/sub/.dagr"
lead_cwd "$TMP_DIR"
run_dagr
assert "a lead cwd outside the repo falls back to the main checkout" '[[ -f $RUN && ! -e $REPO/sub/.dagr ]]'
rm -rf "$REPO/.dagr"
lead_cwd "$REPO-other"
mkdir -p "$REPO-other"
run_dagr
assert "a sibling directory sharing the repo prefix is outside" '[[ -f $RUN && ! -e $REPO-other/.dagr ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
