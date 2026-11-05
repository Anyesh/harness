#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIGHT="$REPO_ROOT/configs/claude-code/bin/crew-light"

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

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
PIDS=()
cleanup() {
  local p f
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for f in "$TMP_DIR"/*.pid; do
    [[ -s $f ]] && kill "$(cat "$f")" 2>/dev/null || true
  done
  command rm -rf "$TMP_DIR"
}
trap cleanup EXIT
export CREW_LIGHT_POLL=0.2
unset CREW_MERGE_GATE

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

MAIN="$TMP_DIR/repo"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
WT="$MAIN/.claude/worktrees/w-1"
git -C "$MAIN" worktree add -q -b w/1 "$WT"
mkdir -p "$WT/sub/dir"
CREW="$MAIN/.claude/crew"
mkdir -p "$CREW"
WAITS="$CREW/light.wait"

RC=0
OUT=
light() {
  RC=0
  OUT=$(cd "${LIGHT_CWD:-$MAIN}" && "$LIGHT" "$@" 2>&1) || RC=$?
}

# Starts crew-light in the background as $BG; the command records its own pid
# in $TMP_DIR/<name>.pid, touches $TMP_DIR/<name>.started and sleeps.
bg_light() {
  local name=$1
  shift
  (cd "${LIGHT_CWD:-$MAIN}" && exec env "$@" "$LIGHT" bash -c "echo \$\$ >'$TMP_DIR/$name.pid'; touch '$TMP_DIR/$name.started'; exec sleep 60") >"$TMP_DIR/$name.out" 2>&1 &
  BG=$!
  PIDS+=("$BG")
}

started() { [[ -e $TMP_DIR/$1.started ]]; }

wait_for() {
  local i
  for ((i = 0; i < 50; i++)); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  return 1
}

stop_command() {
  kill "$(cat "$TMP_DIR/$1.pid")" 2>/dev/null || true
  : >"$TMP_DIR/$1.pid"
}

tickets() { find "$WAITS" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "without light-slots"
light bash -c 'echo ran'
assert "the command runs at once" '[[ $RC -eq 0 && $OUT == ran && ! -e $CREW/light.slots ]]'
light bash -c 'exit 5'
assert "the exit status passes through" '[[ $RC -eq 5 ]]'

echo "validation"
for bad in 0 two -1; do
  printf '%s\n' "$bad" >"$CREW/light-slots"
  light true
  assert "light-slots holding $bad is refused" '[[ $RC -ne 0 && $OUT == *light-slots* ]]'
done
light
assert "no command prints usage and fails" '[[ $RC -ne 0 && $OUT == *usage* ]]'

echo "slots"
printf '2\n' >"$CREW/light-slots"
light bash -c 'exit 7'
assert "the exit status passes through a slot" '[[ $RC -eq 7 ]]'
assert "light-slots without heavy-slots prints a note" '[[ $OUT == *heavy-slots* ]]'
light true
assert "the note is printed once" '[[ $RC -eq 0 && $OUT != *heavy-slots* ]]'

bg_light a
a=$BG
bg_light b
assert "two commands run with two slots" 'wait_for "started a && started b"'
bg_light c
c=$BG
sleep 1
assert "a third waits while both slots are busy" '! started c && kill -0 "$c"'
assert "a waiter outside a worktree writes no ticket" '[[ $(tickets) -eq 0 ]]'
kill -KILL "$a"
wait "$a" 2>/dev/null || true
assert "killing only the wrapper leaves its command running" 'kill -0 "$(cat "$TMP_DIR/a.pid")"'
assert "killing only the wrapper frees its slot" 'wait_for "started c"'
for n in a b c; do stop_command "$n"; done
for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
PIDS=()

echo "merge gate"
printf '1\n' >"$CREW/heavy-slots"
sleep 300 &
MERGER=$!
PIDS+=("$MERGER")
MSTART=$(crew_pid_start "$MERGER")
mkdir -p "$CREW/items/x" "$CREW/heavy.lock"
printf 'merge-x\tmerge gate\t%s\n' "$EPOCHSECONDS" >"$CREW/heavy.lock/holder"
printf 'pid %s\nstart %s\ntip %040d\n' "$MERGER" "$MSTART" 0 >"$CREW/items/x/merging"

LIGHT_CWD=$WT/sub/dir bg_light g
g=$BG
sleep 1
assert "no command starts while a running merge holds the heavy slot" '! started g && kill -0 "$g"'
ticket=$(find "$WAITS" -type f 2>/dev/null | head -n 1)
assert "a waiter in a worktree subdirectory keeps a light.wait ticket named like a heavy ticket" '[[ $(tickets) -eq 1 && ${ticket##*/} =~ ^[0-9]{20}\.$g\.1$ ]] && crew_heavy_ticket_live "$ticket"'
OUT=$(cd "$MAIN" && CREW_MERGE_GATE=1 timeout 5 "$LIGHT" bash -c 'echo gated-ok' 2>&1) && RC=0 || RC=$?
assert "CREW_MERGE_GATE=1 starts at once under the gate" '[[ $RC -eq 0 && $OUT == gated-ok ]]'
RC=0
(cd "$MAIN" && timeout 1 "$LIGHT" true) >/dev/null 2>&1 || RC=$?
assert "without CREW_MERGE_GATE a new command waits under the gate" '[[ $RC -eq 124 ]]'

printf 'pid %s\nstart %s\ntip %040d\n' "$MERGER" "$((MSTART + 1))" 0 >"$CREW/items/x/merging"
assert "a stale merge marker does not pause the waiter" 'wait_for "started g"'
assert "a waiter that took a slot removes its ticket" '[[ $(tickets) -eq 0 ]]'
light bash -c 'echo stale-ok'
assert "a merge-x hold with a stale marker does not pause a new command" '[[ $RC -eq 0 && $OUT == stale-ok ]]'
stop_command g
wait "$g" 2>/dev/null || true

printf 'pid %s\nstart %s\ntip %040d\n' "$MERGER" "$MSTART" 0 >"$CREW/items/x/merging"
LIGHT_CWD=$WT bg_light t
t=$BG
assert "a waiter at the worktree root writes a ticket" 'wait_for "[[ \$(tickets) -eq 1 ]]"'
kill -TERM "$t"
rc=0
wait "$t" 2>/dev/null || rc=$?
assert "a terminated waiter exits at once and removes its ticket" '[[ $rc -eq 143 && $(tickets) -eq 0 ]] && ! started t'

printf 'stack\tstack\t%s\n' "$EPOCHSECONDS" >"$CREW/heavy.lock/holder"
light bash -c 'echo item-ok'
assert "an item holding the heavy slot does not pause light commands" '[[ $RC -eq 0 && $OUT == item-ok ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
