#!/usr/bin/env bash
set -euo pipefail

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
unset CREW_SUCCESSION_POLL CREW_SUCCESSION_RETRIES

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WAIT="$REPO_ROOT/configs/claude-code/bin/crew-succession-wait"
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
    printf '        rc %s output: %s\n' "${RC:-}" "${OUT//$'\n'/$'\n        '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'command rm -rf "$TMP_DIR"' EXIT

export CREW_SUCCESSION_POLL=0.05
export FAKE_STATE="$TMP_DIR/state"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Fake herdr: `agent list`, `tab list` and `pane list` print <cmd>.<n>.json on
# their n-th call (from 1) when that file exists, else <cmd>.json, and fail
# while the count in <cmd>.fail is above zero; any other call is logged to
# unexpected and fails.
cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_STATE
case "$1 $2" in
"agent list") c=agents ;;
"tab list") c=tabs ;;
"pane list") c=panes ;;
*)
  echo "$*" >>"$d/unexpected"
  exit 2
  ;;
esac
f=$(cat "$d/$c.fail" 2>/dev/null || echo 0)
if ((f > 0)); then
  echo $((f - 1)) >"$d/$c.fail"
  echo "herdr: cannot reach server socket" >&2
  exit 1
fi
n=$(($(cat "$d/$c.calls" 2>/dev/null || echo 0) + 1))
echo "$n" >"$d/$c.calls"
if [[ -f $d/$c.$n.json ]]; then cat "$d/$c.$n.json"; else cat "$d/$c.json"; fi
EOF
chmod +x "$FAKE_BIN/herdr"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
CREW=$(crew_dir "$REPO")
ME=w1:p1
SUCC=w1:p9

# agents [suffix] pane[=name]...: agent list with one agent on each pane.
agents() {
  local file=$FAKE_STATE/agents${1:+.$1}.json
  shift
  jq -n '{result: {agents: [$ARGS.positional[] | split("=") |
    {name: (.[1] // null), pane_id: .[0], tab_id: "t-\(.[0])", agent_status: "idle",
     agent_session: {value: "s-\(.[0])"}}]}}' --args "$@" >"$file"
}

# tabs label=tab_id...: tab list; panes pane=tab_id...: pane list.
tabs() {
  jq -n '{result: {tabs: [$ARGS.positional[] | split("=") | {label: .[0], tab_id: .[1], pane_count: 1}]}}' \
    --args "$@" >"$FAKE_STATE/tabs.json"
}
panes() {
  jq -n '{result: {panes: [$ARGS.positional[] | split("=") | {pane_id: .[0], tab_id: .[1], agent_status: "unknown"}]}}' \
    --args "$@" >"$FAKE_STATE/panes.json"
}

reset() {
  command rm -rf "$FAKE_STATE" "$CREW"
  mkdir -p "$FAKE_STATE" "$CREW"
  agents "" "$ME=r-lead"
  tabs "other=w1:t1" "r-l1=w1:t9"
  panes "$ME=w1:t1" "$SUCC=w1:t9"
}

lead_is() { printf '%s\t%s\n' "$1" "s-$1" >"$CREW/lead"; }

run() {
  RC=0
  OUT=$(cd "$REPO" && HERDR_PANE_ID=$ME "$WAIT" "$@" 2>/dev/null) || RC=$?
}

calls() { cat "$FAKE_STATE/$1.calls" 2>/dev/null || echo 0; }
untouched() {
  [[ ! -s $FAKE_STATE/unexpected && $(ls -A "$CREW") == lead && $(cat "$CREW/lead") == "$1"$'\t'"s-$1" ]]
}

echo "taken"
reset
lead_is "$SUCC"
agents "" "$ME=r-old1" "$SUCC=r-lead"
run r-l1 5
assert "a live other lead pane prints TAKEN and exits 0" '[[ $RC -eq 0 && $OUT == "TAKEN $SUCC" ]]'
assert "nothing is written or closed" 'untouched "$SUCC"'

reset
lead_is "$SUCC"
agents 1 "$ME=r-old1"
agents "" "$ME=r-old1" "$SUCC"
run r-l1 5
assert "one miss before herdr lists the pane is still TAKEN" '[[ $RC -eq 0 && $OUT == "TAKEN $SUCC" ]]'

echo "orphaned"
reset
lead_is "$SUCC"
agents "" "$ME=r-old1" "w1:p5=r-lead"
run r-l1 5
assert "an other lead pane with no agent on two polls prints ORPHANED and exits 1" \
  '[[ $RC -eq 1 && $OUT == "ORPHANED $SUCC" && $(calls agents) -eq 2 ]]'
assert "nothing is written" 'untouched "$SUCC"'

echo "lead file"
reset
run r-l1 5
assert "no lead file prints ERROR lead-file and exits 4" '[[ $RC -eq 4 && $OUT == "ERROR lead-file" ]]'
printf '\t\n' >"$CREW/lead"
run r-l1 5
assert "a lead file with no pane prints ERROR lead-file" '[[ $RC -eq 4 && $OUT == "ERROR lead-file" ]]'

echo "failed"
reset
lead_is "$ME"
tabs "other=w1:t1"
run r-l1 5
assert "no tab labelled with the name prints FAILED gone and exits 2" '[[ $RC -eq 2 && $OUT == "FAILED gone" ]]'
assert "nothing is written" 'untouched "$ME"'

reset
lead_is "$ME"
agents "" "$ME=r-lead" "w1:p5=r-l1"
run r-l1 5
assert "the tab's pane with no agent on two polls prints FAILED no-agent and exits 2" \
  '[[ $RC -eq 2 && $OUT == "FAILED no-agent" && $(calls agents) -eq 2 ]]'

reset
lead_is "$ME"
agents 1 "$ME=r-old1" "$SUCC=r-lead"
agents 2 "$ME=r-old1" "$SUCC=r-lead"
agents "" "$ME=r-old1"
run r-l1 5
assert "an agent renamed away from the name counts until its pane empties" \
  '[[ $RC -eq 2 && $OUT == "FAILED no-agent" && $(calls agents) -eq 4 ]]'

reset
lead_is "$ME"
agents 1 "$ME=r-lead"
agents "" "$ME=r-lead" "$SUCC"
run r-l1 1
assert "one miss on the tab's pane is not FAILED" '[[ $RC -eq 3 && $OUT == WAITING ]]'

echo "waiting"
reset
lead_is "$ME"
agents "" "$ME=r-lead" "$SUCC=r-l1"
start=$SECONDS
run r-l1 1
assert "a live successor that has not taken the lead prints WAITING at max seconds and exits 3" \
  '[[ $RC -eq 3 && $OUT == WAITING && $((SECONDS - start)) -ge 1 && $((SECONDS - start)) -le 4 ]]'
assert "it polled more than once" '[[ $(calls agents) -gt 2 ]]'
assert "nothing is written" 'untouched "$ME"'

reset
lead_is "$ME"
agents 1 "$ME=r-lead" "$SUCC=r-l1"
agents "" "$ME=r-old1" "$SUCC=r-lead"
(sleep 0.3 && lead_is "$SUCC") &
run r-l1 5
wait
assert "a lead file written mid-wait is read on the next poll" '[[ $RC -eq 0 && $OUT == "TAKEN $SUCC" ]]'

echo "herdr failures"
reset
lead_is "$SUCC"
echo 2 >"$FAKE_STATE/agents.fail"
agents "" "$SUCC"
run r-l1 5
assert "a transient agent list failure is retried" '[[ $RC -eq 0 && $OUT == "TAKEN $SUCC" ]]'

reset
lead_is "$SUCC"
echo 100 >"$FAKE_STATE/agents.fail"
CREW_SUCCESSION_RETRIES=3 run r-l1 5
assert "agent list failing past the retries prints ERROR and exits 4" \
  '[[ $RC -eq 4 && $OUT == "ERROR agent-list" && $(cat "$FAKE_STATE/agents.fail") -eq 97 ]]'

reset
lead_is "$ME"
echo 100 >"$FAKE_STATE/tabs.fail"
CREW_SUCCESSION_RETRIES=3 run r-l1 5
assert "tab list failing past the retries prints ERROR tab-list" '[[ $RC -eq 4 && $OUT == "ERROR tab-list" ]]'

reset
lead_is "$ME"
echo 100 >"$FAKE_STATE/panes.fail"
CREW_SUCCESSION_RETRIES=3 run r-l1 5
assert "pane list failing past the retries prints ERROR pane-list" '[[ $RC -eq 4 && $OUT == "ERROR pane-list" ]]'

reset
lead_is "$SUCC"
echo 'not json' >"$FAKE_STATE/agents.json"
CREW_SUCCESSION_RETRIES=2 run r-l1 5
assert "unreadable agent list output counts as a failure" '[[ $RC -eq 4 && $OUT == "ERROR agent-list" ]]'

echo "usage"
reset
lead_is "$ME"
run
assert "no name is a usage error" '[[ $RC -eq 4 && -z $OUT ]]'
run r-l1 soon
assert "a non-numeric max is a usage error" '[[ $RC -eq 4 && -z $OUT ]]'
RC=0
OUT=$(cd "$REPO" && "$WAIT" r-l1 5 2>/dev/null) || RC=$?
assert "no HERDR_PANE_ID prints ERROR pane-id" '[[ $RC -eq 4 && $OUT == "ERROR pane-id" ]]'
assert "usage errors call no herdr" '[[ $(calls agents) -eq 0 && $(calls tabs) -eq 0 ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
