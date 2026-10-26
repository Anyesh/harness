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

TMP_DIR=$(mktemp -d)
BG_PID_FILE="$TMP_DIR/bg.pid"
cleanup() {
  if [[ -s $BG_PID_FILE ]]; then kill "$(cat "$BG_PID_FILE")" 2>/dev/null || true; fi
  command rm -rf "$TMP_DIR"
}
trap cleanup EXIT
export CREW_RUNS_DIR="$TMP_DIR/runs"

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
cp /proc/\$pid/stat '$TMP_DIR/stat.snap'
env >'$TMP_DIR/env.snap'"
rc=0
(cd "$(wt_of 11)" && exec env HARNESS_UNATTENDED=1 HARNESS_NOTIFY=0 "${PB[@]}" "$CM" 11) >"$TMP_DIR/out" 2>&1 &
cm_pid=$!
wait "$cm_pid" || rc=$?
landed=$(git -C "$MAIN" rev-parse main)
stat=$(cat "$TMP_DIR/stat.snap")
read -ra stat_f <<<"${stat##*) }"
assert "lands with the push block, crew variables and merge.autostash=true set" '[[ $rc -eq 0 && $(tail -n 1 "$TMP_DIR/out") == "$landed" ]]'
assert "lands the merge commit by fast-forward" '[[ $(git -C "$MAIN" rev-parse "main^1") == "$before" && $(git -C "$MAIN" rev-parse "main^2") == "$tip" ]]'
assert "leaves no MERGE_AUTOSTASH in the target" '! git -C "$MAIN" rev-parse -q --verify MERGE_AUTOSTASH >/dev/null'
assert "merging carries the pid of crew-merge" 'grep -qx "pid $cm_pid" "$TMP_DIR/merging.snap"'
assert "merging carries the pid start time" 'grep -qx "start ${stat_f[19]}" "$TMP_DIR/merging.snap"'
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
assert "two concurrent runs serialize their checks" '[[ $(tr "\n" " " <"$TMP_DIR/serial") == "start end start end " ]]'
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
