#!/usr/bin/env bash
set -euo pipefail

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
while read -r v; do unset "$v"; done < <(compgen -e | grep '^GIT_CONFIG_' || true)
unset CREW_SPAWN_DEADLINE CREW_SPAWN_PROMPT_TIMEOUT CREW_SPAWN_POLL CREW_SPAWN_START_MS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPAWN="$REPO_ROOT/configs/claude-code/bin/crew-spawn"

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

export CREW_SPAWN_POLL=0.05 CREW_SPAWN_PROMPT_TIMEOUT=3
export FAKE_STATE="$TMP_DIR/state"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_STATE
pop() {
  local first
  [[ -s $d/$1 ]] || return 1
  first=$(head -n 1 "$d/$1")
  tail -n +2 "$d/$1" >"$d/$1.tmp" && mv "$d/$1.tmp" "$d/$1"
  printf '%s\n' "$first"
}
case "$1 $2" in
"agent get")
  if [[ -f $d/get_fail ]]; then
    echo "herdr: cannot reach server socket" >&2
    exit 1
  fi
  if [[ -f $d/agent-$3 ]]; then
    printf '{"result":{"agent":{"name":"%s","pane_id":"w1:p2"}}}\n' "$3"
  else
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"},"id":"cli:agent:get"}\n' "$3" >&2
    exit 1
  fi
  ;;
"tab list") cat "$d/tabs.json" ;;
"tab create")
  shift 2
  printf '%s\n' "$@" >"$d/create.args"
  echo '{"result":{"tab":{"tab_id":"w1:t9"},"root_pane":{"pane_id":"w1:p9"}}}'
  ;;
"pane process-info")
  echo x >>"$d/pi.calls"
  state=$(pop pi.queue) || state=$(cat "$d/pi")
  echo "pi $state" >>"$d/events"
  case $state in
  prompt) fg=100 procs='[{"name":"zsh","pid":100}]' ;;
  busy) fg=200 procs='[{"name":"direnv","pid":200}]' ;;
  claude) fg=300 procs='[{"name":"claude","pid":300}]' ;;
  native) fg=300 procs='[{"name":"2.1.318","argv0":"claude","pid":300}]' ;;
  esac
  printf '{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":%s,"foreground_processes":%s}}}\n' "$fg" "$procs"
  ;;
"agent start")
  shift 2
  echo "$*" >>"$d/start.log"
  echo start >>"$d/events"
  rc=$(pop start.rc) || rc=0
  if next=$(pop start.after); then
    IFS=, read -ra states <<<"$next"
    printf '%s\n' "${states[@]:0:${#states[@]}-1}" | grep . >"$d/pi.queue"
    echo "${states[-1]}" >"$d/pi"
  fi
  if ((rc)); then
    echo '{"error":{"code":"agent_not_ready","message":"not ready"}}'
  else
    echo '{"result":{"agent":{"name":"x"}}}'
  fi
  exit "$rc"
  ;;
*)
  echo "fake herdr: unexpected $*" >&2
  exit 9
  ;;
esac
EOF

cat >"$FAKE_BIN/claude-profile" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_STATE/profile.calls"
[[ "$1 $2" == "env p1" ]] || exit 1
printf 'CLAUDE_PROFILE=p1\nCLAUDE_CONFIG_DIR=/x/p 1\n'
EOF
chmod +x "$FAKE_BIN/herdr" "$FAKE_BIN/claude-profile"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" remote add origin https://example.invalid/o.git
git -C "$REPO" remote add upstream https://example.invalid/u.git
mkdir -p "$REPO/sub"
MAIN=$(cd "$REPO" && pwd -P)

reset() {
  command rm -rf "$FAKE_STATE"
  mkdir -p "$FAKE_STATE"
  echo '{"result":{"tabs":[{"label":"other","tab_id":"w1:t1"}]}}' >"$FAKE_STATE/tabs.json"
  echo prompt >"$FAKE_STATE/pi"
}

spawn() {
  RC=0
  OUT=$(cd "$REPO/sub" && "$SPAWN" "$@" 2>&1) || RC=$?
}

has() { grep -qxF -- "$1" <<<"$OUT"; }
arg() { grep -qxF -- "$1" "$FAKE_STATE/create.args" 2>/dev/null; }
after() { grep -A1 -xF -- "$1" "$FAKE_STATE/create.args" 2>/dev/null | tail -n 1; }
starts() { if [[ -f $FAKE_STATE/start.log ]]; then wc -l <"$FAKE_STATE/start.log" | tr -d ' '; else echo 0; fi; }

echo "env and tab create"
reset
spawn r-w1 p1
assert "exits 0 and prints the pane" '[[ $RC -eq 0 ]] && has "pane w1:p9"'
assert "tab gets the label, main checkout and no focus" \
  '[[ $(after --label) == r-w1 && $(after --cwd) == "$MAIN" ]] && arg --no-focus'
assert "unattended and notify off" 'arg HARNESS_UNATTENDED=1 && arg HARNESS_NOTIFY=0'
assert "profile env passed, value with a space kept whole" \
  'arg CLAUDE_PROFILE=p1 && arg "CLAUDE_CONFIG_DIR=/x/p 1"'
assert "push URLs reset then dead for each remote" \
  'arg GIT_CONFIG_KEY_0=remote.origin.pushurl && arg GIT_CONFIG_VALUE_0= &&
   arg GIT_CONFIG_KEY_1=remote.origin.pushurl && arg GIT_CONFIG_VALUE_1=/nonexistent/crew-no-push &&
   arg GIT_CONFIG_KEY_2=remote.upstream.pushurl && arg GIT_CONFIG_VALUE_2= &&
   arg GIT_CONFIG_KEY_3=remote.upstream.pushurl && arg GIT_CONFIG_VALUE_3=/nonexistent/crew-no-push &&
   arg GIT_CONFIG_COUNT=4'
assert "every env value follows its own --env" \
  '[[ $(grep -cxF -- --env "$FAKE_STATE/create.args") -eq 13 ]]'
assert "agent start with skip-permissions after the end-of-options marker" \
  '[[ $(cat "$FAKE_STATE/start.log") == "r-w1 --kind claude --pane w1:p9 --timeout 120000 -- --dangerously-skip-permissions" ]]'

echo "default profile"
reset
spawn r-w2 default
assert "default profile runs no claude-profile and adds no profile env" \
  '[[ $RC -eq 0 && ! -f $FAKE_STATE/profile.calls ]] && ! grep -q "^CLAUDE_" "$FAKE_STATE/create.args"'

echo "repo with no remotes"
reset
NOREMOTE="$TMP_DIR/noremote"
git init -q "$NOREMOTE"
RC=0
OUT=$(cd "$NOREMOTE" && "$SPAWN" r-w3 default 2>&1) || RC=$?
assert "no remotes means no GIT_CONFIG env" \
  '[[ $RC -eq 0 ]] && ! grep -q "^GIT_CONFIG" "$FAKE_STATE/create.args"'

echo "unknown profile"
reset
spawn r-w4 nope
assert "a failing claude-profile stops before tab create" \
  '[[ $RC -eq 4 && ! -f $FAKE_STATE/create.args ]]'

echo "existing agent or tab"
reset
touch "$FAKE_STATE/agent-r-w5"
spawn r-w5 default
assert "an existing agent prints exists and exits 3 with no tab create" \
  '[[ $RC -eq 3 ]] && has "exists r-w5" && [[ ! -f $FAKE_STATE/create.args ]]'
reset
echo '{"result":{"tabs":[{"label":"other","tab_id":"w1:t1"},{"label":"r-w6","tab_id":"w1:t2"}]}}' >"$FAKE_STATE/tabs.json"
spawn r-w6 default
assert "an existing tab label prints exists and exits 3 with no tab create" \
  '[[ $RC -eq 3 ]] && has "exists r-w6" && [[ ! -f $FAKE_STATE/create.args ]]'
reset
touch "$FAKE_STATE/get_fail"
spawn r-w7 default
assert "a failing agent get is an error, not a missing agent" \
  '[[ $RC -eq 4 && ! -f $FAKE_STATE/create.args ]] && ! has "exists r-w7"'

echo "prompt poll"
reset
printf 'busy\nbusy\n' >"$FAKE_STATE/pi.queue"
spawn r-w8 default
assert "agent start waits until the shell is at its prompt" \
  '[[ $RC -eq 0 && $(tr "\n" " " <"$FAKE_STATE/events") == "pi busy pi busy pi prompt start " ]]'
reset
echo busy >"$FAKE_STATE/pi"
CREW_SPAWN_PROMPT_TIMEOUT=1 spawn r-w9 default
assert "no prompt within the timeout: pane printed, no start, exit 4" \
  '[[ $RC -eq 4 ]] && has "pane w1:p9" && [[ $(starts) -eq 0 ]]'

echo "retries"
reset
printf '1\n1\n0\n' >"$FAKE_STATE/start.rc"
spawn r-w10 default
assert "retried while the shell is at its prompt" '[[ $RC -eq 0 && $(starts) -eq 3 ]]'
reset
printf '1\n' >"$FAKE_STATE/start.rc"
echo claude,prompt >"$FAKE_STATE/start.after"
spawn r-w11 default
assert "no retry once claude is in the foreground; status passes through" \
  '[[ $RC -eq 1 && $(starts) -eq 1 ]] && has "pane w1:p9"'
reset
printf '1\n' >"$FAKE_STATE/start.rc"
echo native,prompt >"$FAKE_STATE/start.after"
spawn r-w17 default
assert "the native install counts as claude by its argv0" \
  '[[ $RC -eq 1 && $(starts) -eq 1 ]]'
reset
printf '1\n' >"$FAKE_STATE/start.rc"
echo busy,busy,claude >"$FAKE_STATE/start.after"
spawn r-w12 default
assert "a failed start waits out a busy foreground before deciding" \
  '[[ $RC -eq 1 && $(tr "\n" " " <"$FAKE_STATE/events") == "pi prompt start pi busy pi busy pi claude " ]]'
reset
printf '2\n2\n2\n2\n' >"$FAKE_STATE/start.rc"
spawn r-w13 default
assert "three tries at most, and the last failure status passes through" \
  '[[ $RC -eq 2 && $(starts) -eq 3 ]] && has "pane w1:p9"'

echo "deadline"
reset
CREW_SPAWN_DEADLINE=5 spawn r-w14 default
assert "agent start timeout is capped by the time left" \
  '[[ $RC -eq 0 ]] && t=$(sed -n "s/.*--timeout \([0-9]*\) .*/\1/p" "$FAKE_STATE/start.log") && ((t > 0 && t <= 5000))'
reset
printf '1\n1\n1\n' >"$FAKE_STATE/start.rc"
CREW_SPAWN_START_MS=7 spawn r-w15 default
assert "agent start timeout is configurable" \
  '[[ $(head -n 1 "$FAKE_STATE/start.log") == *"--timeout 7 --"* ]]'

echo "usage"
reset
spawn r-w16
assert "missing profile is a usage error with no herdr call" \
  '[[ $RC -eq 4 && ! -f $FAKE_STATE/create.args ]]'
spawn Bad_Name default
assert "a name herdr would reject fails before any herdr call" \
  '[[ $RC -eq 4 && ! -f $FAKE_STATE/create.args ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
