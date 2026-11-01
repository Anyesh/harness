#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEAVY="$REPO_ROOT/configs/claude-code/bin/crew-heavy"

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
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  command rm -rf "$TMP_DIR"
}
trap cleanup EXIT
export CREW_HEAVY_POLL=0.2

MAIN="$TMP_DIR/repo"
git init -q "$MAIN"
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q -b w/1 "$MAIN/.claude/worktrees/w-1"
CREW="$MAIN/.claude/crew"
mkdir -p "$CREW"
LOCK="$CREW/heavy.lock"
WT="$MAIN/.claude/worktrees/w-1"

RC=0
OUT=
heavy() {
  RC=0
  OUT=$(cd "${HEAVY_CWD:-$MAIN}" && "$HEAVY" "$@" 2>&1) || RC=$?
}

holder_field() { cut -f"$1" "$LOCK/holder"; }
QUEUE="$CREW/heavy.queue"
tickets() { find "$QUEUE" -type f 2>/dev/null | wc -l; }

echo "acquire and release"
heavy status
assert "status of a free slot is free" '[[ $RC -eq 0 && $OUT == free ]]'
before=$EPOCHSECONDS
HEAVY_CWD=$WT heavy acquire 1 "browser check"
assert "acquire from a worktree takes the main checkout's crew lock" '[[ $RC -eq 0 && -d $LOCK ]]'
assert "the holder file is holder, purpose and epoch, tab-separated" '[[ $(holder_field 1) == 1 && $(holder_field 2) == "browser check" && $(holder_field 3) -ge $before && $(awk -F"\t" "{print NF}" "$LOCK/holder") == 3 ]]'
heavy status
assert "status names the holder, purpose and minutes held" '[[ $OUT == "held by 1 for browser check, 0 min" ]]'
heavy acquire 1 "browser check"
assert "the holder acquiring again succeeds at once" '[[ $RC -eq 0 && $OUT == *"already holds"* ]]'
heavy acquire 2 "stack" 0
assert "another holder gives up after its max wait, naming the holder" '[[ $RC -ne 0 && $OUT == *"held by: 1"* && $(holder_field 1) == 1 ]]'
assert "giving up removes the waiter's ticket" '[[ $(tickets) -eq 0 ]]'
heavy release 2
assert "another holder cannot release the slot" '[[ $RC -ne 0 && -d $LOCK && $(holder_field 1) == 1 ]]'
heavy release 1
assert "the holder releases the slot" '[[ $RC -eq 0 && ! -e $LOCK ]]'
heavy release 1
assert "releasing a free slot succeeds" '[[ $RC -eq 0 && ! -e $LOCK ]]'

echo "waiting"
heavy acquire 1 stack
(cd "$MAIN" && exec "$HEAVY" acquire 2 suite 30) >"$TMP_DIR/wait.out" 2>&1 &
waiter=$!
PIDS+=("$waiter")
sleep 1
assert "a second holder waits while the slot is held" 'kill -0 "$waiter" && [[ $(holder_field 1) == 1 ]]'
heavy release 1
rc=0
wait "$waiter" || rc=$?
assert "the waiting holder takes the slot once it is released" '[[ $rc -eq 0 && $(holder_field 1) == 2 && $(holder_field 2) == suite ]]'
heavy release 2
assert "a waiter that took the slot leaves no ticket behind" '[[ $(tickets) -eq 0 ]]'

echo "queue order"
heavy acquire 1 stack
: >"$TMP_DIR/order"
for w in 2:1 3:0.5 4:0.1; do
  (cd "$MAIN" && CREW_HEAVY_POLL=${w#*:} exec "$HEAVY" run "${w%%:*}" suite 30 -- bash -c "echo ${w%%:*} >>'$TMP_DIR/order'; sleep 0.5") >/dev/null 2>&1 &
  PIDS+=("$!")
  sleep 0.5
done
heavy status
assert "status keeps its first line and lists the waiters in arrival order" '[[ $OUT == "held by 1 for stack, 0 min"$'\''\n'\''"waiting: 2, 3, 4" ]]'
heavy release 1
for p in "${PIDS[@]: -3}"; do wait "$p" || true; done
assert "waiters take the slot in arrival order, however often each polls" '[[ $(paste -sd" " "$TMP_DIR/order") == "2 3 4" && ! -e $LOCK && $(tickets) -eq 0 ]]'

heavy acquire 1 stack
(cd "$MAIN" && exec "$HEAVY" acquire 2 suite 30) >/dev/null 2>&1 &
dead=$!
sleep 0.5
kill -KILL "$dead"
wait "$dead" 2>/dev/null || true
(cd "$MAIN" && exec "$HEAVY" acquire 3 suite 30) >/dev/null 2>&1 &
waiter=$!
PIDS+=("$waiter")
sleep 0.5
heavy release 1
rc=0
wait "$waiter" || rc=$?
assert "a waiter whose process died does not block the queue" '[[ $rc -eq 0 && $(holder_field 1) == 3 && $(tickets) -eq 0 ]]'
heavy release 3

heavy acquire 1 stack
mkdir -p "$QUEUE"
: >"$QUEUE/00000000000000000001.$$.9"
(cd "$MAIN" && exec "$HEAVY" acquire 3 suite 30) >/dev/null 2>&1 &
waiter=$!
PIDS+=("$waiter")
sleep 0.5
heavy release 1
rc=0
wait "$waiter" || rc=$?
assert "a ticket whose pid now belongs to a newer process does not block the queue" '[[ $rc -eq 0 && $(holder_field 1) == 3 && $(tickets) -eq 0 ]]'
heavy release 3

heavy acquire 1 stack
(cd "$MAIN" && exec "$HEAVY" acquire 2 suite 30) >/dev/null 2>&1 &
first=$!
PIDS+=("$first")
sleep 0.5
heavy acquire 1 stack
assert "the holder acquiring again skips the queue" '[[ $RC -eq 0 && $OUT == *"already holds"* && $(tickets) -eq 1 ]]'
heavy acquire 3 suite 1
assert "a waiter behind another gives up at its max wait and removes its ticket" '[[ $RC -ne 0 && $(tickets) -eq 1 ]]'
kill -TERM "$first"
rc=0
wait "$first" 2>/dev/null || rc=$?
assert "a terminated waiter removes its ticket" '[[ $rc -eq 143 && $(tickets) -eq 0 && $(holder_field 1) == 1 ]]'
heavy release 1

echo "run"
heavy run 3 "suite" -- bash -c "cut -f1 '$LOCK/holder'"
assert "run holds the slot while its command runs" '[[ $RC -eq 0 ]] && grep -qx 3 <<<"$OUT"'
assert "run releases the slot after the command" '[[ ! -e $LOCK ]]'
heavy run 3 "suite" 5 -- bash -c "exit 7"
assert "run releases the slot and keeps the status when the command fails" '[[ $RC -eq 7 && ! -e $LOCK ]]'
(cd "$MAIN" && exec "$HEAVY" run 3 suite -- sleep 2) >/dev/null 2>&1 &
runner=$!
PIDS+=("$runner")
for _ in $(seq 50); do
  [[ -f $LOCK/holder ]] && break
  sleep 0.1
done
kill -TERM "$runner"
sleep 0.5
assert "a terminated run keeps the slot while its command still runs" '[[ -d $LOCK ]]'
rc=0
wait "$runner" 2>/dev/null || rc=$?
assert "a terminated run releases the slot once its command ends" '[[ $rc -eq 143 && ! -e $LOCK ]]'
heavy run 3 suite
assert "run without -- is refused" '[[ $RC -ne 0 && ! -e $LOCK ]]'

echo "validation"
heavy acquire "a b" stack
assert "a holder that is not an id or name is refused" '[[ $RC -ne 0 && ! -e $LOCK ]]'
printf '2\n' >"$CREW/heavy-slots"
heavy acquire 1 stack
assert "a heavy-slots file other than 1 is refused" '[[ $RC -ne 0 && $OUT == *heavy-slots* && ! -e $LOCK ]]'
printf '1\n' >"$CREW/heavy-slots"
heavy acquire 1 stack
assert "heavy-slots holding 1 allows the slot" '[[ $RC -eq 0 && -d $LOCK ]]'
heavy release 1
heavy bogus
assert "an unknown subcommand prints usage and fails" '[[ $RC -ne 0 && $OUT == *usage* ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
