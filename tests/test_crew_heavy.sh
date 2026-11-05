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

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"
sleep 300 &
MERGER=$!
PIDS+=("$MERGER")
MSTART=$(crew_pid_start "$MERGER")
SHA=$(printf '%040d' 7)
marker() {
  mkdir -p "$CREW/items/$1"
  case $2 in
    queued) printf 'pid %s\nstart %s\ntip %s\nqueued %s\n' "$MERGER" "$MSTART" "$SHA" "$EPOCHSECONDS" ;;
    running) printf 'pid %s\nstart %s\ntip %s\n' "$MERGER" "$MSTART" "$SHA" ;;
    stale) printf 'pid %s\nstart %s\ntip %s\n' "$MERGER" "$((MSTART + 1))" "$SHA" ;;
  esac >"$CREW/items/$1/merging"
}
live_ticket() {
  mkdir -p "$QUEUE"
  printf '%s/%020d.%s.%s' "$QUEUE" "$((10#${EPOCHREALTIME//[!0-9]/}))" "$MERGER" "$1"
}
ORDER="$TMP_DIR/served"
QUEUED=()
queue_run() {
  local h=$1
  shift
  (cd "$MAIN" && exec env "$@" "$HEAVY" run "$h" suite 30 -- bash -c "echo $h >>'$ORDER'; sleep 0.3") >/dev/null 2>&1 &
  PIDS+=("$!")
  QUEUED+=("$!")
  sleep 0.5
}
drain() {
  local p
  for p in "${QUEUED[@]}"; do wait "$p" 2>/dev/null || true; done
  QUEUED=()
}
served() { paste -sd" " "$ORDER"; }

echo "priority order"
printf '1\n' >"$CREW/heavy-slots"
: >"$ORDER"
heavy acquire 1 stack
queue_run 2
queue_run merge-x
heavy status
assert "status lists a merge ahead of an older normal waiter" '[[ $OUT == "held by 1 for stack, 0 min"$'\''\n'\''"waiting: merge-x, 2" ]]'
heavy release 1
drain
assert "a merge queued after a normal waiter takes the slot first" '[[ $(served) == "merge-x 2" && ! -e $LOCK && $(tickets) -eq 0 ]]'

: >"$ORDER"
heavy acquire 1 stack
queue_run merge-a
queue_run 2
queue_run 3
printf '3\n' >"$CREW/heavy-priority"
heavy status
assert "a waiter granted heavy-priority while queued goes ahead of older normal waiters, not older merges" '[[ $OUT == *"waiting: merge-a, 3, 2" ]]'
heavy release 1
drain
assert "the granted waiter is served in that order without restarting" '[[ $(served) == "merge-a 3 2" && $(tickets) -eq 0 ]]'

: >"$ORDER"
heavy acquire 1 stack
queue_run 2
queue_run 3
heavy status
assert "a granted waiter is listed first" '[[ $OUT == *"waiting: 3, 2" ]]'
: >"$CREW/heavy-priority"
heavy status
assert "removing it from heavy-priority demotes it" '[[ $OUT == *"waiting: 2, 3" ]]'
heavy release 1
drain
assert "a demoted waiter is served after older normal waiters" '[[ $(served) == "2 3" && $(tickets) -eq 0 ]]'
rm "$CREW/heavy-priority"

echo "merging markers"
marker x queued
heavy acquire 2 suite 1
assert "a queued merging marker with no hold or ticket keeps a normal waiter off a free slot" '[[ $RC -ne 0 && ! -e $LOCK && $OUT == *"1 ahead"* && $(tickets) -eq 0 ]]'
marker x running
heavy acquire 2 suite 1
assert "a running merging marker with no hold or ticket keeps a normal waiter off a free slot" '[[ $RC -ne 0 && ! -e $LOCK && $OUT == *"1 ahead"* ]]'
mt=$(live_ticket merge-x)
: >"$mt"
heavy acquire 2 suite 1
assert "a marker whose merge has a ticket counts once" '[[ $RC -ne 0 && $OUT == *"1 ahead"* ]]'
rm "$mt"
heavy acquire merge-x "merge gate" 0
heavy acquire 2 suite 1
assert "a marker whose merge holds the slot adds no one ahead" '[[ $RC -ne 0 && $OUT == *"0 ahead"* && $(holder_field 1) == merge-x ]]'
heavy release merge-x
printf '2\n' >"$CREW/heavy-priority"
heavy acquire 2 suite 0
assert "a heavy-priority waiter is not held back by a marker" '[[ $RC -eq 0 && $(holder_field 1) == 2 ]]'
heavy release 2
rm "$CREW/heavy-priority"
rm "$CREW/heavy-slots"
heavy acquire 2 suite 0
assert "without heavy-slots a marker holds no one back" '[[ $RC -eq 0 && $(holder_field 1) == 2 ]]'
heavy release 2
printf '1\n' >"$CREW/heavy-slots"
marker x stale
heavy acquire 2 suite 0
assert "a stale marker holds no one back" '[[ $RC -eq 0 && $(holder_field 1) == 2 ]]'
heavy release 2
rm -rf "$CREW/items"

echo "aging"
: >"$ORDER"
heavy acquire 1 stack 0
marker y queued
queue_run 2 CREW_HEAVY_AGE=2
sleep 2
queue_run merge-x CREW_HEAVY_AGE=2
heavy release 1
drain
assert "with CREW_HEAVY_AGE=2 an aged normal ticket beats a younger merge and a queued marker" '[[ $(served) == "2 merge-x" && $(tickets) -eq 0 ]]'
marker y running
(cd "$MAIN" && CREW_HEAVY_AGE=2 exec "$HEAVY" acquire 2 suite 10) >/dev/null 2>&1 &
aged=$!
PIDS+=("$aged")
sleep 1
assert "a young normal waiter stays off a free slot while a merge runs" '[[ ! -e $LOCK ]] && kill -0 "$aged"'
rc=0
wait "$aged" || rc=$?
assert "once aged it takes the free slot despite the running marker" '[[ $rc -eq 0 && $(holder_field 1) == 2 ]]'
heavy release 2
rm -rf "$CREW/items"

echo "holds"
heavy holds 1
assert "holds exits 1 with no output on a free slot" '[[ $RC -eq 1 && -z $OUT ]]'
heavy acquire 1 stack
heavy holds 1
assert "holds exits 0 with no output for the holder" '[[ $RC -eq 0 && -z $OUT ]]'
heavy holds 2
assert "holds exits 1 with no output for anyone else" '[[ $RC -eq 1 && -z $OUT ]]'
heavy holds
assert "holds without a holder prints usage and fails" '[[ $RC -ne 0 && $OUT == *usage* ]]'

echo "old-format tickets"
old=$(live_ticket w.1)
: >"$old"
heavy status
assert "status lists a ticket written by the old code, dots in its holder kept" '[[ $OUT == *"waiting: w.1" ]]'
heavy release 1
heavy acquire 2 suite 1
assert "a normal waiter queues behind an old-format ticket" '[[ $RC -ne 0 && $OUT == *"1 ahead"* && ! -e $LOCK ]]'
heavy acquire merge-z "merge gate" 0
assert "a merge goes ahead of an old-format ticket" '[[ $RC -eq 0 && $(holder_field 1) == merge-z && -e $old ]]'
heavy release merge-z
rm "$old"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
