#!/usr/bin/env bash
set -euo pipefail

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
for v in $(compgen -e); do
  if [[ $v == GIT_CONFIG_* ]]; then unset "$v"; fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CM="$REPO_ROOT/configs/claude-code/bin/crew-merge"

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

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
BG_PID_FILE="$TMP_DIR/bg.pid"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  if [[ -s $BG_PID_FILE ]]; then kill "$(cat "$BG_PID_FILE")" 2>/dev/null || true; fi
  command rm -rf "$TMP_DIR"
}
trap cleanup EXIT
export CREW_RUNS_DIR="$TMP_DIR/runs"
export CREW_MERGE_POLL=0.2

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

REAL_GIT=$(command -v git)
export REAL_GIT
mkdir -p "$TMP_DIR/nohooks"

REMOTE="$TMP_DIR/remote.git"
git init -q --bare -b main "$REMOTE"
MAIN="$TMP_DIR/repo"
git init -q -b main "$MAIN"
MAIN=$(cd "$MAIN" && pwd -P)
git -C "$MAIN" config user.email t@t
git -C "$MAIN" config user.name t
git -C "$MAIN" config core.hooksPath "$TMP_DIR/nohooks"
echo base >"$MAIN/file"
git -C "$MAIN" add file
git -C "$MAIN" commit -q -m init
git -C "$MAIN" remote add origin "$REMOTE"
git -C "$MAIN" remote add upstream "$REMOTE"
git -C "$MAIN" push -q -u origin main

CREW="$MAIN/.claude/crew"
mkdir -p "$CREW/items"
: >"$CREW/board.tsv"
RUNS="$CREW_RUNS_DIR/$(crew_slug "$MAIN")"
LOCK="$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir)/crew-merge.lock"

set_check() {
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$1" >"$CREW/check"
  chmod +x "$CREW/check"
}

wt_of() { printf '%s/.claude/worktrees/w-%s' "$MAIN" "$1"; }

new_item() {
  local id=$1 into=${2:-main} wt tip
  wt=$(wt_of "$id")
  git -C "$MAIN" worktree add -q -b "w/$id" "$wt" main
  echo "$id" >"$wt/f-$id"
  git -C "$wt" add "f-$id"
  git -C "$wt" commit -q -m "item $id"
  tip=$(git -C "$wt" rev-parse HEAD)
  printf '%s\tassigned\tw1\tw/%s\t%s\t0\tdeliverable %s\n' "$id" "$id" "$into" "$id" >>"$CREW/board.tsv"
  mkdir -p "$CREW/items/$id"
  printf 'looks fine\nverdict: green\nreviewed: %s\n' "$tip" >"$CREW/items/$id/review.md"
}

tip_of() { git -C "$MAIN" rev-parse "refs/heads/w/$1"; }

run_merge() { (cd "$(wt_of "$1")" && exec "$CM" "$1"); }

no_leftover() {
  ! git -C "$MAIN" worktree list --porcelain | grep -qF "worktree $RUNS/merge-" &&
    ! compgen -G "$RUNS/merge-*" >/dev/null
}

refuses() {
  local name=$1 id=$2 pattern=$3 before rc=0
  before=$(git -C "$MAIN" rev-parse main)
  run_merge "$id" >"$TMP_DIR/out" 2>&1 || rc=$?
  assert "refuses $name" '[[ $rc -ne 0 && $(git -C "$MAIN" rev-parse main) == "$before" && ! -e "$CREW/items/$id/merged" ]] && grep -q "$pattern" "$TMP_DIR/out" && no_leftover'
  assert "removes merging after refusing $name" '[[ ! -e "$CREW/items/$id/merging" ]]'
}

push_block() {
  local n=0 r
  PB=()
  for r in $(git -C "$1" remote); do
    PB+=("GIT_CONFIG_KEY_$n=remote.$r.pushurl" "GIT_CONFIG_VALUE_$n=")
    n=$((n + 1))
    PB+=("GIT_CONFIG_KEY_$n=remote.$r.pushurl" "GIT_CONFIG_VALUE_$n=/nonexistent/crew-no-push")
    n=$((n + 1))
  done
  PB+=("GIT_CONFIG_COUNT=$n")
}

remote_main() { git -C "$REMOTE" rev-parse refs/heads/main; }

push_block "$MAIN"
git -C "$MAIN" commit -q --allow-empty -m ahead
pushed=$(remote_main)
assert "without the push block a push would go through" 'git -C "$MAIN" push -q --dry-run origin main 2>/dev/null'
env "${PB[@]}" git -C "$MAIN" push -q origin main 2>/dev/null || true
assert "push block stops git push origin" '[[ $(remote_main) == "$pushed" ]]'
env "${PB[@]}" git -C "$MAIN" push -q 2>/dev/null || true
assert "push block stops a bare git push" '[[ $(remote_main) == "$pushed" ]]'
env "${PB[@]}" git -C "$MAIN" push -q upstream main 2>/dev/null || true
assert "push block covers every remote" '[[ $(remote_main) == "$pushed" ]]'
git -C "$MAIN" config remote.origin.pushurl "$REMOTE"
env "${PB[@]}" git -C "$MAIN" push -q origin main 2>/dev/null || true
assert "push block holds against the repo's own pushurl (git push origin)" '[[ $(remote_main) == "$pushed" ]]'
env "${PB[@]}" git -C "$MAIN" push -q 2>/dev/null || true
assert "push block holds against the repo's own pushurl (bare git push)" '[[ $(remote_main) == "$pushed" ]]'
assert "push block leaves git fetch origin working" 'env "${PB[@]}" git -C "$MAIN" fetch -q origin'

set_check 'exit 0'

new_item 1
command rm "$CREW/items/1/review.md"
refuses "with no review.md" 1 "review"

new_item 2
printf 'verdict: green\nreviewed: %s\nverdict: changes\n' "$(tip_of 2)" >"$CREW/items/2/review.md"
refuses "a non-green last verdict" 2 "verdict"

new_item 3
git -C "$(wt_of 3)" commit -q --allow-empty -m "after review"
refuses "a tip that is not the reviewed sha" 3 "reviewed"

new_item 4
printf 'verdict: green\nreviewed: %s\n' "$(tip_of 4 | cut -c1-12)" >"$CREW/items/4/review.md"
refuses "an abbreviated reviewed sha" 4 "reviewed"

new_item 5
command rm "$CREW/check"
refuses "a missing check" 5 "check"
set_check 'echo check-says-no; exit 1'
refuses "a failing check" 5 "check-says-no"
set_check 'exit 0'

new_item 6
echo dirty >>"$MAIN/file"
refuses "a dirty target" 6 "uncommitted"
git -C "$MAIN" checkout -q file

new_item 7
mh=$(git -C "$MAIN" rev-parse --path-format=absolute --git-path MERGE_HEAD)
git -C "$MAIN" rev-parse HEAD >"$mh"
refuses "a target with a leftover MERGE_HEAD" 7 "MERGE_HEAD"
command rm "$mh"

new_item 8
ma=$(git -C "$MAIN" rev-parse --path-format=absolute --git-path MERGE_AUTOSTASH)
git -C "$MAIN" rev-parse HEAD >"$ma"
refuses "a target with a leftover MERGE_AUTOSTASH" 8 "MERGE_AUTOSTASH"
command rm "$ma"

new_item 9
set_check "git -C '$MAIN' switch -q -c sidetrack"
refuses "a target switched to another branch at the same sha during check" 9 "checked out"
assert "the switched-to branch is not advanced either" '[[ $(git -C "$MAIN" rev-parse sidetrack) == "$(git -C "$MAIN" rev-parse main)" ]]'
git -C "$MAIN" switch -q main
git -C "$MAIN" branch -q -D sidetrack
set_check 'exit 0'

git -C "$MAIN" branch -q release main
new_item 10 release
refuses "a target branch checked out nowhere" 10 "release"

new_item 11
git -C "$MAIN" config merge.autostash true
tip=$(tip_of 11)
before=$(git -C "$MAIN" rev-parse main)
set_check "m='$CREW/items/11/merging'
pid=\$(sed -n 's/^pid //p' \"\$m\" | tail -n 1)
cp \"\$m\" '$TMP_DIR/merging.snap'
. '$REPO_ROOT/configs/claude-code/bin/crew-lib.sh'
crew_pid_start \$pid >'$TMP_DIR/start.snap'
env >'$TMP_DIR/env.snap'"
rc=0
(cd "$(wt_of 11)" && exec env HARNESS_UNATTENDED=1 HARNESS_NOTIFY=0 "${PB[@]}" "$CM" 11) >"$TMP_DIR/out" 2>&1 &
cm_pid=$!
wait "$cm_pid" || rc=$?
landed=$(git -C "$MAIN" rev-parse main)
start=$(cat "$TMP_DIR/start.snap")
assert "lands with the push block, crew variables and merge.autostash=true set" '[[ $rc -eq 0 && $(tail -n 1 "$TMP_DIR/out") == "$landed" ]]'
assert "lands the merge commit by fast-forward" '[[ $(git -C "$MAIN" rev-parse "main^1") == "$before" && $(git -C "$MAIN" rev-parse "main^2") == "$tip" ]]'
assert "leaves no MERGE_AUTOSTASH in the target" '! git -C "$MAIN" rev-parse -q --verify MERGE_AUTOSTASH >/dev/null'
assert "merging carries the pid of crew-merge" 'grep -qx "pid $cm_pid" "$TMP_DIR/merging.snap"'
assert "merging carries the start time crew_pid_start reads for that pid" '[[ -n $start ]] && grep -qx "start $start" "$TMP_DIR/merging.snap"'
assert "merging carries the tip" 'grep -qx "tip $tip" "$TMP_DIR/merging.snap"'
assert "merging becomes merged" '[[ ! -e "$CREW/items/11/merging" && -f "$CREW/items/11/merged" ]]'
assert "merged records branch, tip, merged sha and into" 'grep -qx "branch w/11" "$CREW/items/11/merged" && grep -qx "tip $tip" "$CREW/items/11/merged" && grep -qx "merged $landed" "$CREW/items/11/merged" && grep -qx "into main" "$CREW/items/11/merged"'
assert "check sees neither HARNESS_UNATTENDED nor HARNESS_NOTIFY" '! grep -q "^HARNESS_UNATTENDED=\|^HARNESS_NOTIFY=" "$TMP_DIR/env.snap"'
assert "check sees no GIT_CONFIG_ variable" '! grep -q "^GIT_CONFIG_" "$TMP_DIR/env.snap"'
assert "no merge worktree is left behind" 'no_leftover'
set_check 'exit 0'

new_item 12
tip=$(tip_of 12)
set_check "git -C '$(wt_of 12)' commit -q --allow-empty -m 'during check'"
run_merge 12 >"$TMP_DIR/out" 2>&1
assert "merges the resolved tip when the branch moves during check" '[[ $(git -C "$MAIN" rev-parse "main^2") == "$tip" && $(tip_of 12) != "$tip" ]]'
set_check 'exit 0'

new_item 13
set_check "sleep 30 &
echo \$! >'$BG_PID_FILE'"
run_merge 13 >"$TMP_DIR/out" 2>&1
assert "a background child of check does not hold the lock" 'flock -n "$LOCK" true'
kill "$(cat "$BG_PID_FILE")"
: >"$BG_PID_FILE"
set_check 'exit 0'

new_item 14
new_item 15
set_check "echo start >>'$TMP_DIR/serial'
sleep 1
echo end >>'$TMP_DIR/serial'"
rc14=0
rc15=0
run_merge 14 >"$TMP_DIR/out14" 2>&1 &
p14=$!
run_merge 15 >"$TMP_DIR/out15" 2>&1 &
p15=$!
wait "$p14" || rc14=$?
wait "$p15" || rc15=$?
assert "two concurrent runs both land" '[[ $rc14 -eq 0 && $rc15 -eq 0 ]] && git -C "$MAIN" merge-base --is-ancestor "$(tip_of 14)" main && git -C "$MAIN" merge-base --is-ancestor "$(tip_of 15)" main'
assert "two concurrent runs never overlap their checks" '[[ $(tr "\n" " " <"$TMP_DIR/serial") =~ ^(start\ end\ )+$ ]]'
set_check 'exit 0'

FAKE="$TMP_DIR/fakebin"
mkdir -p "$FAKE"
cat >"$FAKE/git" <<'FAKEGIT'
#!/usr/bin/env bash
rc=0
"$REAL_GIT" "$@" || rc=$?
args=("$@")
while [[ ${args[0]:-} == -c || ${args[0]:-} == -C ]]; do args=("${args[@]:2}"); done
if [[ $rc -eq 0 && ${args[0]:-} == merge && " ${args[*]} " == *" --ff-only "* ]]; then
  kill -KILL "$CREW_KILL_PID"
fi
exit "$rc"
FAKEGIT
chmod +x "$FAKE/git"

new_item 16
(cd "$(wt_of 16)" && PATH="$FAKE:$PATH" exec bash -c 'export CREW_KILL_PID=$$; exec "$0" 16' "$CM") >"$TMP_DIR/out" 2>&1 &
{ wait $! || true; } 2>/dev/null
recorded=$(sed -n 's/^merged //p' "$CREW/items/16/merging" | tail -n 1)
assert "SIGKILL after the fast-forward leaves merging with the merged sha" '[[ -n $recorded && $(git -C "$MAIN" rev-parse main) == "$recorded" && ! -e "$CREW/items/16/merged" ]]'
leftover=$(git -C "$MAIN" worktree list --porcelain | sed -n "s|^worktree \($RUNS/merge-.*\)|\1|p")
assert "the killed run leaves its temp worktree behind" '[[ -n $leftover && -d $leftover ]]'

new_item 17
run_merge 17 >"$TMP_DIR/out" 2>&1
assert "the next run clears a leftover temp worktree" '[[ -f "$CREW/items/17/merged" && ! -e $leftover ]] && no_leftover'

HEAVY="$REPO_ROOT/configs/claude-code/bin/crew-heavy"
HLOCK="$CREW/heavy.lock"
export CREW_HEAVY_POLL=0.2

new_item 30
set_check "[[ ! -e '$HLOCK' ]]"
run_merge 30 >"$TMP_DIR/out" 2>&1 || true
assert "without heavy-slots check runs without the heavy slot" '[[ -f "$CREW/items/30/merged" && ! -e $HLOCK ]]'

echo 1 >"$CREW/heavy-slots"
new_item 31
set_check "cut -f1,2 '$HLOCK/holder' >'$TMP_DIR/holder.snap'"
run_merge 31 >"$TMP_DIR/out" 2>&1 || true
assert "with heavy-slots check holds the slot as merge-<id> for the merge gate" '[[ -f "$CREW/items/31/merged" && $(<"$TMP_DIR/holder.snap") == "merge-31"$'"'"'\t'"'"'"merge gate" ]]'
assert "the slot is free after a landed merge" '[[ ! -e $HLOCK ]]'

new_item 32
set_check "[[ -d '$HLOCK' ]] && echo held-then-failed; exit 1"
refuses "a failing check under the heavy slot" 32 "held-then-failed"
assert "the slot is free after a failed check" '[[ ! -e $HLOCK ]]'
set_check 'exit 0'

new_item 33
(cd "$MAIN" && "$HEAVY" acquire 7 stack >/dev/null)
before=$(git -C "$MAIN" rev-parse main)
rc=0
(cd "$(wt_of 33)" && CREW_HEAVY_MERGE_WAIT=1 exec "$CM" 33) >"$TMP_DIR/out" 2>&1 || rc=$?
assert "a merge gives up when the slot stays held past its wait" '[[ $rc -ne 0 && $(git -C "$MAIN" rev-parse main) == "$before" && ! -e "$CREW/items/33/merged" ]] && grep -q "held by: 7" "$TMP_DIR/out" && no_leftover'
assert "giving up keeps the other holder's slot and frees the merge lock" '[[ $(cut -f1 "$HLOCK/holder") == 7 ]] && flock -n "$LOCK" true'

run_merge 33 >"$TMP_DIR/out" 2>&1 &
p21=$!
sleep 1
assert "a merge waits for the slot after its temporary merge" 'kill -0 "$p21" && [[ ! -e "$CREW/items/33/merged" ]]'
(cd "$MAIN" && "$HEAVY" release 7 >/dev/null)
rc=0
wait "$p21" || rc=$?
assert "the waiting merge lands once the slot is released and frees it" '[[ $rc -eq 0 && -f "$CREW/items/33/merged" && ! -e $HLOCK ]]'

n=34
for sig in HUP:129 TERM:143; do
  want=${sig#*:} sig=${sig%:*}
  new_item "$n"
  command rm -f "$TMP_DIR/started"
  set_check "touch '$TMP_DIR/started'; sleep 2"
  before=$(git -C "$MAIN" rev-parse main)
  (cd "$(wt_of "$n")" && CREW_HEAVY_MERGE_WAIT=5 exec "$CM" "$n") >"$TMP_DIR/out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do
    [[ -e $TMP_DIR/started ]] && break
    sleep 0.1
  done
  kill -"$sig" "$pid"
  rc=0
  wait "$pid" || rc=$?
  assert "$sig during check frees the slot and lands nothing" '[[ $rc -eq $want && ! -e $HLOCK && $(git -C "$MAIN" rev-parse main) == "$before" && ! -e "$CREW/items/$n/merged" ]] && no_leftover'
  n=$((n + 1))
done

new_item 37
set_check "printf '%s' \"\${CREW_MERGE_GATE:-}\" >'$TMP_DIR/gate.snap'"
run_merge 37 >"$TMP_DIR/out" 2>&1 || true
assert "check runs with CREW_MERGE_GATE=1" '[[ -f "$CREW/items/37/merged" && $(<"$TMP_DIR/gate.snap") == 1 ]]'
set_check 'exit 0'

HQUEUE="$CREW/heavy.queue"
heavy_tickets() { find "$HQUEUE" -type f 2>/dev/null | wc -l | tr -d ' '; }

new_item 38
(cd "$MAIN" && "$HEAVY" acquire 38 stack >/dev/null)
(
  exec {fd}>"$LOCK"
  flock "$fd"
  exec sleep 30
) &
echo $! >"$BG_PID_FILE"
until ! flock -n "$LOCK" true; do sleep 0.1; done
t0=$SECONDS
(cd "$(wt_of 38)" && CREW_HEAVY_MERGE_WAIT=2 exec "$CM" 38) >"$TMP_DIR/out" 2>&1 &
p38=$!
for _ in $(seq 50); do
  [[ $(heavy_tickets) -eq 0 ]] || break
  kill -0 "$p38" 2>/dev/null || break
  sleep 0.1
done
seen=$(heavy_tickets)
rc=0
wait "$p38" || rc=$?
assert "a merge whose item holds the heavy slot refuses before waiting for the merge lock" '[[ $rc -eq 1 && $seen -eq 0 ]] && ((SECONDS - t0 < 10)) && grep -q "crew-heavy release 38" "$TMP_DIR/out"'
assert "the refusal writes no marker and keeps the item's slot" '[[ ! -e "$CREW/items/38/merging" && ! -e "$CREW/items/38/merged" && $(cut -f1 "$HLOCK/holder") == 38 && $(heavy_tickets) -eq 0 ]]'
(cd "$MAIN" && "$HEAVY" release 38 >/dev/null)

start_queued() {
  (cd "$(wt_of "$1")" && CREW_HEAVY_MERGE_WAIT=2 exec "$CM" "$1") >"$TMP_DIR/out" 2>&1 &
  QBG=$!
  for _ in $(seq 100); do
    grep -q '^queued ' "$CREW/items/$1/merging" 2>/dev/null && return 0
    sleep 0.1
  done
}
start_queued 38
assert "a merge waits on the merge lock while the item's slot is free" 'kill -0 "$QBG" && grep -q "^queued " "$CREW/items/38/merging"'
echo 38 >"$CREW/heavy-priority"
(cd "$MAIN" && "$HEAVY" acquire 38 stack >/dev/null)
command rm "$CREW/heavy-priority"
kill "$(cat "$BG_PID_FILE")"
: >"$BG_PID_FILE"
seen=0
while kill -0 "$QBG" 2>/dev/null; do
  seen=$((seen + $(heavy_tickets)))
  sleep 0.05
done
rc=0
wait "$QBG" || rc=$?
assert "a slot the item took during the lock wait refuses before the heavy acquire" '[[ $rc -eq 1 && $seen -eq 0 ]] && grep -q "crew-heavy release 38" "$TMP_DIR/out"'
assert "that refusal removes its marker and keeps the item's slot" '[[ ! -e "$CREW/items/38/merging" && ! -e "$CREW/items/38/merged" && $(cut -f1 "$HLOCK/holder") == 38 ]] && no_leftover'
(cd "$MAIN" && "$HEAVY" release 38 >/dev/null)
command rm "$CREW/heavy-slots"

new_item 36
(
  exec {fd}>"$LOCK"
  flock "$fd"
  exec sleep 30
) &
echo $! >"$BG_PID_FILE"
until ! flock -n "$LOCK" true; do sleep 0.1; done
for shebang in '/usr/bin/env bash' /bin/sh; do
  printf '#!%s\nif then\n' "$shebang" >"$CREW/check"
  t0=$SECONDS
  refuses "a $shebang check with a syntax error" 36 "syntax error"
  assert "a $shebang check with a syntax error fails without waiting for the merge lock" '((SECONDS - t0 < 10))'
done
kill "$(cat "$BG_PID_FILE")"
: >"$BG_PID_FILE"
printf '#!/usr/bin/env false\nif then\n' >"$CREW/check"
refuses "a check in another language without a bash syntax check" 36 "check failed"
set_check 'exit 0'
marker() { printf '%s/items/%s/merging' "$CREW" "$1"; }
marker_pid() { awk '$1 == "pid" {v = $2} END {print v}' "$(marker "$1")" 2>/dev/null; }
dead_pid() {
  sleep 0 &
  local p=$!
  wait "$p"
  echo "$p"
}
wait_for() {
  local i
  for ((i = 0; i < 100; i++)); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  return 1
}
# Backgrounding run_merge would fork a subshell around it, so $! would not be
# the crew-merge pid.
start_merge() {
  (cd "$(wt_of "$1")" && exec "$CM" "$1") >"$2" 2>&1 &
  BG=$!
  PIDS+=("$BG")
}
HOLDER=
hold_lock() {
  command rm -f "$TMP_DIR/held"
  (
    exec {fd}>"$LOCK"
    flock "$fd"
    : >"$TMP_DIR/held"
    exec sleep 120
  ) &
  HOLDER=$!
  PIDS+=("$HOLDER")
  wait_for '[[ -e $TMP_DIR/held ]]'
}

# Holds an item's marker lock, so runs started meanwhile all contend for it
# when release_marker frees it.
hold_marker() {
  command rm -f "$TMP_DIR/mheld"
  (
    exec {fd}>"$CREW/items/$1/.marker.lock"
    flock "$fd"
    : >"$TMP_DIR/mheld"
    exec sleep 120
  ) &
  MHOLDER=$!
  PIDS+=("$MHOLDER")
  wait_for '[[ -e $TMP_DIR/mheld ]]'
}
release_marker() {
  sleep 0.5
  kill "$MHOLDER"
}

new_item 18
hold_lock
start_merge 18 "$TMP_DIR/out18"
p18=$BG
assert "a run waiting on the merge queue marks itself queued" 'wait_for "grep -q \"^queued \" \"$(marker 18)\" 2>/dev/null"'
status_out=$(cd "$MAIN" && "$CM" --status)
assert "--status lists a queued run as QUEUED without waiting for the lock" 'grep -qx "QUEUED 18" <<<"$status_out"'
before18=$(cat "$(marker 18)")
rc=0
run_merge 18 >"$TMP_DIR/out" 2>&1 || rc=$?
assert "a second run of an item already merging exits 3 and leaves the marker" '[[ $rc -eq 3 && $(cat "$(marker 18)") == "$before18" ]] && grep -q "already merging" "$TMP_DIR/out"'
(sleep 10 && kill -KILL "$p18" 2>/dev/null) &
watchdog=$!
kill -TERM "$p18"
rc=0
wait "$p18" || rc=$?
kill "$watchdog" 2>/dev/null || true
assert "SIGTERM while queued exits 143 within seconds and removes merging" '[[ $rc -eq 143 && ! -e $(marker 18) ]]'

new_item 19
printf 'pid %s\nstart 1\ntip %s\n' "$(dead_pid)" "$(tip_of 19)" >"$(marker 19)"
hold_marker 19
start_merge 19 "$TMP_DIR/out19a"
p19a=$BG
start_merge 19 "$TMP_DIR/out19b"
p19b=$BG
release_marker
wait_for 'grep -q "already merging" "$TMP_DIR/out19a" "$TMP_DIR/out19b"' || true
if grep -q "already merging" "$TMP_DIR/out19a"; then loser=$p19a winner=$p19b; else loser=$p19b winner=$p19a; fi
rc=0
wait "$loser" || rc=$?
assert "two runs against one stale marker leave one live marker, and the other exits 3" '[[ $rc -eq 3 && $(marker_pid 19) == "$winner" && $(crew_merge_state "$(marker 19)") == queued ]]'

new_item 20
printf 'pid %s\nstart 1\ntip %s\n' "$(dead_pid)" "$(tip_of 20)" >"$(marker 20)"
hold_marker 20
start_merge 20 "$TMP_DIR/out20"
p20=$BG
(cd "$MAIN" && exec "$CM" --settle 20) >/dev/null 2>&1 &
settle_pid=$!
release_marker
wait "$settle_pid" || true
wait_for '[[ $(marker_pid 20) == "$p20" ]]' || true
assert "a --settle racing a rerun never removes the rerun's live marker" '[[ $(marker_pid 20) == "$p20" && $(crew_merge_state "$(marker 20)") == queued ]]'

kill "$HOLDER"
rc19=0
rc20=0
wait "$winner" || rc19=$?
wait "$p20" || rc20=$?
assert "the queued runs land once the queue frees" '[[ $rc19 -eq 0 && $rc20 -eq 0 && -f $CREW/items/19/merged && -f $CREW/items/20/merged ]]'

new_item 21
main_sha=$(git -C "$MAIN" rev-parse main)
printf 'pid %s\nstart 1\ntip %s\nmerged %s\n' "$(dead_pid)" "$(tip_of 21)" "$main_sha" >"$(marker 21)"
before21=$(cat "$(marker 21)")
rc=0
run_merge 21 >"$TMP_DIR/out" 2>&1 || rc=$?
assert "a run over a cut marker exits 1, names --settle and leaves the marker" '[[ $rc -eq 1 && $(cat "$(marker 21)") == "$before21" ]] && grep -q -- "--settle 21" "$TMP_DIR/out"'

settle() {
  RC=0
  SETTLE_OUT=$(cd "$MAIN" && "$CM" --settle "$1" 2>&1) || RC=$?
}
settle 21
assert "--settle writes merged for a cut marker whose sha is in the target" '[[ $RC -eq 0 && ! -e $(marker 21) ]] && grep -qx "branch w/21" "$CREW/items/21/merged" && grep -qx "tip $(tip_of 21)" "$CREW/items/21/merged" && grep -qx "merged $main_sha" "$CREW/items/21/merged" && grep -qx "into main" "$CREW/items/21/merged" && grep -q landed <<<"$SETTLE_OUT"'

new_item 22
printf 'pid %s\nstart 1\ntip %s\nmerged %s\n' "$(dead_pid)" "$(tip_of 22)" "$(tip_of 22)" >"$(marker 22)"
settle 22
assert "--settle removes a cut marker whose sha is not in the target" '[[ $RC -eq 0 && ! -e $(marker 22) && ! -e $CREW/items/22/merged ]]'

mkdir -p "$CREW/items/23"
printf 'pid %s\nstart 1\ntip %040d\n' "$(dead_pid)" 0 >"$(marker 23)"
settle 23
assert "--settle removes a stale marker of an item off the board" '[[ $RC -eq 0 && ! -e $(marker 23) ]]'

sleep 60 &
live=$!
PIDS+=("$live")
mkdir -p "$CREW/items/24" "$CREW/items/26" "$CREW/items/27" "$CREW/items/99"
printf 'pid %s\nstart %s\ntip %040d\n' "$live" "$(crew_pid_start "$live")" 0 >"$(marker 24)"
settle 24
assert "--settle refuses a live marker with exit 3" '[[ $RC -eq 3 && -e $(marker 24) ]]'

printf 'pid %s\nstart 1\ntip %040d\nmerged %s\n' "$(dead_pid)" 0 "$main_sha" >"$(marker 99)"
settle 99
assert "--settle refuses a cut marker of an item off the board" '[[ $RC -eq 1 && -e $(marker 99) ]] && grep -q "not on the board" <<<"$SETTLE_OUT"'

settle 25
assert "--settle with no marker has nothing to do" '[[ $RC -eq 0 ]]'

mkdir -p "$CREW/items/099"
printf 'pid %s\nstart 1\ntip %040d\nmerged %s\n' "$(dead_pid)" 0 "$main_sha" >"$(marker 099)"
printf '99\tdone\tw1\tw/99\tmain\t0\tnumeric twin\n' >>"$CREW/board.tsv"
settle 099
assert "--settle matches the board id as text, so 099 is not row 99" '[[ $RC -eq 1 && -e $(marker 099) ]] && grep -q "not on the board" <<<"$SETTLE_OUT"'
command rm -r "$CREW/items/099"

printf 'pid %s\nstart %s\ntip %040d\nqueued 1\n' "$live" "$(crew_pid_start "$live")" 0 >"$(marker 26)"
printf 'pid %s\nstart 1\ntip %040d\n' "$(dead_pid)" 0 >"$(marker 27)"
status_out=$(cd "$MAIN" && "$CM" --status)
assert "--status reports RUNNING, QUEUED, CUT with its sha, and STALE" 'grep -qx "RUNNING 24" <<<"$status_out" && grep -qx "QUEUED 26" <<<"$status_out" && grep -qx "CUT 99 $main_sha" <<<"$status_out" && grep -qx "STALE 27" <<<"$status_out"'
command rm -f "$CREW"/items/*/merging
status_out=$(cd "$MAIN" && "$CM" --status)
assert "--status prints nothing when no item is merging" '[[ -z $status_out ]]'

queue_merges() {
  local id
  QP=()
  for id in "$@"; do
    start_merge "$id" "$TMP_DIR/out$id"
    QP+=("$BG")
    wait_for "grep -q '^queued ' '$(marker "$id")' 2>/dev/null"
  done
}
wait_queued() {
  local p r
  RCS=()
  for p in "${QP[@]}"; do
    r=0
    wait "$p" || r=$?
    RCS+=("$r")
  done
}
gate_items() {
  printf "for i in %s; do if [[ -e f-\$i ]] && ! git -C '%s' cat-file -e HEAD:f-\$i 2>/dev/null; then printf '%%s ' \$i; fi; done >>'%s'; echo >>'%s'" "$*" "$MAIN" "$TMP_DIR/gates" "$TMP_DIR/gates"
}
merged_sha() { awk '$1 == "merged" {print $2}' "$CREW/items/$1/merged" 2>/dev/null; }
no_markers() {
  local id
  for id; do [[ ! -e $(marker "$id") ]] || return 1; done
}
reflog_count() { git -C "$MAIN" reflog show refs/heads/main | wc -l | tr -d ' '; }

new_item 40
new_item 41
new_item 42
: >"$TMP_DIR/gates"
set_check "$(gate_items 40 41 42)
'$CM' --status >'$TMP_DIR/status.snap'"
before=$(git -C "$MAIN" rev-parse main)
flog=$(reflog_count)
hold_lock
queue_merges 40 41 42
kill "$HOLDER"
wait_queued
assert "a batch of three queued items lands every one" '[[ ${RCS[*]} == "0 0 0" ]]'
assert "a batch runs check once on all its items merged together" '[[ $(cat "$TMP_DIR/gates") == "40 41 42 " ]]'
assert "a batch lands the items in queue order, each with its own merge commit" '[[ $(git -C "$MAIN" rev-parse main^2) == "$(tip_of 42)" && $(git -C "$MAIN" rev-parse main^1^2) == "$(tip_of 41)" && $(git -C "$MAIN" rev-parse main^1^1^2) == "$(tip_of 40)" && $(git -C "$MAIN" rev-parse main^1^1^1) == "$before" ]]'
assert "each batched item gets a merged file naming its own merge commit" '[[ $(merged_sha 42) == "$(git -C "$MAIN" rev-parse main)" && $(merged_sha 41) == "$(git -C "$MAIN" rev-parse main^1)" && $(merged_sha 40) == "$(git -C "$MAIN" rev-parse main^1^1)" ]]'
assert "each batched run prints its own merge commit" '[[ $(tail -n 1 "$TMP_DIR/out40") == "$(merged_sha 40)" && $(tail -n 1 "$TMP_DIR/out41") == "$(merged_sha 41)" && $(tail -n 1 "$TMP_DIR/out42") == "$(merged_sha 42)" ]]'
assert "a batch lands with one fast-forward of the target" '[[ $(reflog_count) -eq $((flog + 1)) ]]'
assert "--status lists every batched item as RUNNING during the gate" 'grep -qx "RUNNING 40" "$TMP_DIR/status.snap" && grep -qx "RUNNING 41" "$TMP_DIR/status.snap" && grep -qx "RUNNING 42" "$TMP_DIR/status.snap"'
assert "a landed batch leaves no marker and no merge worktree" 'no_markers 40 41 42 && no_leftover'

new_item 43
new_item 44
new_item 45
new_item 46
: >"$TMP_DIR/gates"
set_check "$(gate_items 43 44 45 46)
if [[ -e f-45 ]]; then echo bad-45; exit 1; fi"
hold_lock
queue_merges 43 44 45 46
kill "$HOLDER"
wait_queued
assert "bisect lands the good items of a red batch and cuts the bad one" '[[ ${RCS[*]} == "0 0 1 0" && -f $CREW/items/43/merged && -f $CREW/items/44/merged && -f $CREW/items/46/merged && ! -e $CREW/items/45/merged ]]'
assert "the cut item never reaches the target" '! git -C "$MAIN" merge-base --is-ancestor "$(tip_of 45)" main'
assert "the cut run shows the failing log and names it" 'grep -q bad-45 "$TMP_DIR/out45" && grep -q "log: $RUNS/" "$TMP_DIR/out45"'
assert "bisect gates the whole batch first and the bad item alone at last" '[[ $(head -n 1 "$TMP_DIR/gates") == "43 44 45 46 " ]] && grep -qx "45 " "$TMP_DIR/gates" && (($(wc -l <"$TMP_DIR/gates") <= 4))'
assert "a bisected batch leaves no marker and no merge worktree" 'no_markers 43 44 45 46 && no_leftover'
set_check 'exit 0'

commit_shared() {
  echo "$2" >"$(wt_of "$1")/shared"
  git -C "$(wt_of "$1")" add shared
  git -C "$(wt_of "$1")" commit -q -m "shared $1"
  printf 'verdict: green\nreviewed: %s\n' "$(tip_of "$1")" >"$CREW/items/$1/review.md"
}
new_item 47
commit_shared 47 forty-seven
new_item 48
commit_shared 48 forty-eight
new_item 49
: >"$TMP_DIR/gates"
set_check "$(gate_items 47 48 49)"
hold_lock
queue_merges 47 48 49
kill "$HOLDER"
wait_queued
assert "an item conflicting with an earlier batched item drops out and the rest land" '[[ ${RCS[0]} -eq 0 && ${RCS[2]} -eq 0 && -f $CREW/items/47/merged && -f $CREW/items/49/merged ]]'
assert "the dropped item is not gated with the batch" '[[ $(head -n 1 "$TMP_DIR/gates") == "47 49 " ]]'
assert "the dropped item runs in the next batch, where its conflict with the target refuses it" '[[ ${RCS[1]} -eq 1 && ! -e $CREW/items/48/merged ]] && grep -q conflict "$TMP_DIR/out48" && no_markers 47 48 49 && no_leftover'

SLOW="$TMP_DIR/slowflock"
mkdir -p "$SLOW"
printf '#!/usr/bin/env bash\nsleep 1\nexec %q "$@"\n' "$(command -v flock)" >"$SLOW/flock"
chmod +x "$SLOW/flock"
for t in 1 2; do
  git -C "$MAIN" worktree add -q -b "fifo$t" "$TMP_DIR/fifo$t" main
  new_item "5$t" "fifo$t"
done
: >"$TMP_DIR/gates"
set_check "$(gate_items 51 52)"
hold_lock
(cd "$(wt_of 51)" && PATH="$SLOW:$PATH" exec "$CM" 51) >"$TMP_DIR/out51" 2>&1 &
QP=("$!")
PIDS+=("$!")
wait_for "grep -q '^queued ' '$(marker 51)' 2>/dev/null"
start_merge 52 "$TMP_DIR/out52"
QP+=("$BG")
sleep 2
kill "$HOLDER"
wait_queued
assert "queued runs take the merge lock in the order they queued, not the order they reach it" '[[ ${RCS[*]} == "0 0" && $(tr -d "\n" <"$TMP_DIR/gates") == "51 52 " ]]'

new_item 55
new_item 56
: >"$TMP_DIR/gates"
command rm -f "$TMP_DIR/started"
set_check "$(gate_items 55 56)
if [[ ! -e '$TMP_DIR/started' ]]; then touch '$TMP_DIR/started'; sleep 2; fi"
hold_lock
queue_merges 55 56
kill "$HOLDER"
wait_for '[[ -e $TMP_DIR/started ]]'
kill -TERM "${QP[0]}"
wait_queued
assert "a batch leader stopped by TERM lands nothing and its follower lands in the next batch" '[[ ${RCS[0]} -eq 143 && ${RCS[1]} -eq 0 && ! -e $CREW/items/55/merged && -f $CREW/items/56/merged ]]'
assert "the follower's next batch holds only itself" '[[ $(tr -d "\n" <"$TMP_DIR/gates") == "55 56 56 " ]] && no_markers 55 56 && no_leftover'

new_item 57
new_item 58
: >"$TMP_DIR/gates"
command rm -f "$TMP_DIR/started"
set_check "$(gate_items 57 58)
if [[ ! -e '$TMP_DIR/started' ]]; then touch '$TMP_DIR/started'; sleep 2; fi"
hold_lock
queue_merges 57 58
kill "$HOLDER"
wait_for '[[ -e $TMP_DIR/started ]]'
kill -KILL "${QP[0]}"
wait_queued
assert "a follower whose batch leader was killed requeues itself and lands" '[[ ${RCS[0]} -eq 137 && ${RCS[1]} -eq 0 && -f $CREW/items/58/merged && ! -e $CREW/items/57/merged ]]'
assert "the killed leader's own marker is left stale for --settle" '[[ $(crew_merge_state "$(marker 57)") == stale ]]'
settle 57

new_item 59
new_item 60
command rm -f "$TMP_DIR/started"
set_check "if [[ ! -e '$TMP_DIR/started' ]]; then touch '$TMP_DIR/started'; sleep 2; fi"
hold_lock
queue_merges 59 60
kill "$HOLDER"
wait_for '[[ -e $TMP_DIR/started ]]'
kill -TERM "${QP[1]}"
wait_queued
assert "a batched follower stopped by TERM still lands with its batch" '[[ ${RCS[0]} -eq 0 && ${RCS[1]} -eq 143 && -f $CREW/items/59/merged && -f $CREW/items/60/merged ]] && no_markers 59 60'
set_check 'exit 0'

new_item 61
printf 'verdict: green\nreviewed: %s\n' "$(git -C "$MAIN" rev-parse main)" >"$CREW/items/61/review.md"
new_item 62
hold_lock
queue_merges 62 61
kill "$HOLDER"
wait_queued
assert "a batch refuses a follower whose review does not name its tip and lands the rest" '[[ ${RCS[0]} -eq 0 && ${RCS[1]} -eq 1 && -f $CREW/items/62/merged && ! -e $CREW/items/61/merged ]] && grep -q reviewed "$TMP_DIR/out61" && no_markers 61 62'

new_item 63
new_item 64
new_item 65
new_item 66
: >"$TMP_DIR/gates"
command rm -f "$TMP_DIR/started" "$TMP_DIR/status.snap"
set_check "$(gate_items 63 64 65 66)
if [[ -e f-65 && ! -e f-66 && ! -e '$TMP_DIR/started' ]]; then '$CM' --status >'$TMP_DIR/status.snap'; touch '$TMP_DIR/started'; sleep 2; fi
if [[ -e f-65 ]]; then exit 1; fi"
hold_lock
queue_merges 63 64 65 66
kill "$HOLDER"
wait_for '[[ -e $TMP_DIR/started ]]'
kill -TERM "${QP[0]}"
wait_queued
assert "a leader whose item landed early in a bisect keeps its marker while it gates the rest" 'grep -qx "RUNNING 63" "$TMP_DIR/status.snap"'
assert "a leader stopped after its own item landed exits 0 with its merge commit" '[[ ${RCS[0]} -eq 0 && $(tail -n 1 "$TMP_DIR/out63") == "$(merged_sha 63)" && -n $(merged_sha 63) ]]'
assert "the rest of that batch lands or is cut in the next batch" '[[ ${RCS[*]} == "0 0 1 0" && -f $CREW/items/66/merged && ! -e $CREW/items/65/merged ]] && no_markers 63 64 65 66 && no_leftover'
set_check 'exit 0'

: >"$TMP_DIR/gates"
set_check "echo ran >>'$TMP_DIR/gates'"
before63=$(merged_sha 63)
touch -d @1 "$CREW/items/63/merged"
rc=0
run_merge 63 >"$TMP_DIR/out" 2>&1 || rc=$?
assert "a rerun of an item already in the target prints its merge commit without a gate" '[[ $(stat -c %Y "$CREW/items/63/merged") -eq 1 && $rc -eq 0 && $(tail -n 1 "$TMP_DIR/out") == "$before63" && $(merged_sha 63) == "$before63" && ! -s $TMP_DIR/gates ]] && no_markers 63'
new_item 72
git -C "$MAIN" merge -q --ff-only "w/72"
rc=0
run_merge 72 >"$TMP_DIR/out" 2>&1 || rc=$?
assert "an item whose tip is already in the target lands at the target head without a gate" '[[ $rc -eq 0 && $(merged_sha 72) == "$(git -C "$MAIN" rev-parse main)" && $(tail -n 1 "$TMP_DIR/out") == "$(merged_sha 72)" && ! -s $TMP_DIR/gates ]] && no_markers 72'
set_check 'exit 0'

new_item 68
new_item 69
new_item 70
new_item 71
echo untracked >"$MAIN/f-71"
set_check "if [[ -e f-70 ]]; then exit 1; fi"
hold_lock
queue_merges 68 69 70 71
kill "$HOLDER"
wait_queued
assert "a leader whose item landed exits 0 with its merge commit when a later fast-forward fails" '[[ ${RCS[0]} -eq 0 && $(tail -n 1 "$TMP_DIR/out68") == "$(merged_sha 68)" && -n $(merged_sha 68) ]]'
assert "the item whose fast-forward failed is left cut for --settle" '[[ ${RCS[1]} -eq 0 && ${RCS[2]} -eq 1 && ${RCS[3]} -eq 1 ]] && grep -q -- "--settle 71" "$TMP_DIR/out71" && [[ $(crew_merge_state "$(marker 71)") == cut* ]]'
assert "the leader names the items to settle when a fast-forward fails" 'grep -q -- "--settle for each of: 71" "$TMP_DIR/out68"'
command rm "$MAIN/f-71"
settle 71
set_check 'exit 0'

new_item 73
new_item 74
git -C "$MAIN" merge -q --ff-only "w/74"
in_target=$(git -C "$MAIN" rev-parse main)
: >"$TMP_DIR/gates"
set_check "$(gate_items 73 74)"
hold_lock
queue_merges 73 74
kill "$HOLDER"
wait_queued
assert "a batched item already in the target lands at the target head without joining the gate" '[[ ${RCS[*]} == "0 0" && $(merged_sha 74) == "$in_target" && $(tail -n 1 "$TMP_DIR/out74") == "$in_target" && $(tr -d "\n" <"$TMP_DIR/gates") == "73 " ]] && no_markers 73 74'
set_check 'exit 0'

new_item 67
hold_lock
(cd "$(wt_of 67)" && LC_ALL=de_DE.UTF-8 exec "$CM" 67) >"$TMP_DIR/out67" 2>&1 &
QP=("$!")
PIDS+=("$!")
wait_for "grep -q '^queued ' '$(marker 67)' 2>/dev/null"
assert "the queue ticket is whole microseconds under a comma-decimal locale" 'grep -Eqx "ticket [0-9]{16,}" "$(marker 67)"'
kill "$HOLDER"
wait_queued
assert "a run under a comma-decimal locale lands" '[[ ${RCS[0]} -eq 0 && -f $CREW/items/67/merged ]]'

new_item 75
new_item 77
git -C "$MAIN" merge -q --ff-only "w/77"
printf 'verdict: changes\nreviewed: %s\n' "$(tip_of 77)" >"$CREW/items/77/review.md"
new_item 78
sleep 60 &
old_run=$!
PIDS+=("$old_run")
printf 'pid %s\nstart %s\ntip %s\nqueued %s\n' "$old_run" "$(crew_pid_start "$old_run")" "$(tip_of 78)" "$((EPOCHSECONDS + 600))" >"$(marker 78)"
hold_lock
queue_merges 75 77
kill "$HOLDER"
wait_queued
assert "a marker the batch did not claim never settles the item claimed before it" '[[ ${RCS[*]} == "0 1" && ! -e $CREW/items/77/merged ]] && grep -q verdict "$TMP_DIR/out77"'
assert "an old-format queued marker is left for its own run" '[[ $(crew_merge_state "$(marker 78)") == queued ]]'
kill "$old_run"
command rm -f "$(marker 78)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
