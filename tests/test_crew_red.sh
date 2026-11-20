#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CR="$REPO_ROOT/configs/claude-code/bin/crew-red"

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
    printf '        out: %s\n' "${OUT//$'\n'/$'\n             '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
export WIKI_VAULT="${TMP_DIR}/vault"
unset HARNESS_WORK
trap 'command rm -rf "$TMP_DIR"' EXIT

MAIN="$TMP_DIR/repo"
git init -q -b main "$MAIN"
git -C "$MAIN" config user.email t@t
git -C "$MAIN" config user.name t
echo base >"$MAIN/file"
git -C "$MAIN" add file
git -C "$MAIN" commit -q -m init
CREW="$MAIN/.claude/crew"
mkdir -p "$CREW/items"
printf 'a1\tassigned\tw1\tw/a1\tmain\t0\tfix the bug\n' >"$CREW/board.tsv"
WT="$MAIN/.claude/worktrees/w-a1"
git -C "$MAIN" worktree add -q -b w/a1 "$WT" main
LOG="$CREW/items/a1/red.log"

OUT=
RC=0
cr_in() {
  local dir=$1
  shift
  RC=0
  OUT=$(cd "$dir" && "$CR" "$@" 2>&1) || RC=$?
}
cr() { cr_in "$WT" "$@"; }
section() { awk -v s="$1:" '$0 == s {f = 1; next} /^[a-z]+:$/ {f = 0} /^red / {f = 0} f' "$LOG"; }

echo "usage"
cr
assert "no arguments exit 2" '[[ $RC -eq 2 ]] && [[ $OUT == *"Usage: crew-red"* ]]'
cr a1
assert "an id without a command exits 2" '[[ $RC -eq 2 ]]'

echo "refusals"
cr a1 true
assert "a passing command is refused" '[[ $RC -eq 1 && ! -e $LOG ]] && [[ $OUT == *passed* ]]'
cr a1 crew-red-no-such-command
assert "a command that is not found is refused" '[[ $RC -eq 1 && ! -e $LOG ]] && [[ $OUT == *"could not run"* ]]'
printf 'echo hi\n' >"$TMP_DIR/noexec"
cr a1 "$TMP_DIR/noexec"
assert "a command that cannot execute is refused" '[[ $RC -eq 1 && ! -e $LOG ]] && [[ $OUT == *"could not run"* ]]'
cr b9 false
assert "an id not on the board is refused" '[[ $RC -eq 1 && ! -e $CREW/items/b9/red.log ]] && [[ $OUT == *"not on the board"* ]]'
cr_in "$MAIN" a1 false
assert "a run off the item's branch is refused" '[[ $RC -eq 1 && ! -e $LOG ]] && [[ $OUT == *"w/a1"* ]]'

echo "record"
echo changed >"$WT/file"
echo new >"$WT/test_new"
cr a1 bash -c 'echo "assertion failed: want 2 got 1"; exit 3'
assert "a failing command is recorded" '[[ $RC -eq 0 && -f $LOG ]]'
assert "the run's output and status are printed" '[[ $OUT == *"assertion failed: want 2 got 1"* && $OUT == *"exit 3"* ]]'
assert "the block starts with a UTC timestamp" 'grep -Eq "^red [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$" "$LOG"'
WANT_CMD=$(printf '%q ' bash -c 'echo "assertion failed: want 2 got 1"; exit 3')
assert "the command is recorded shell-quoted" '[[ $(sed -n "s/^cmd //p" "$LOG") == "${WANT_CMD% }" ]]'
assert "HEAD is recorded" '[[ $(sed -n "s/^head //p" "$LOG") == $(git -C "$WT" rev-parse HEAD) ]]'
assert "the exit status is recorded" '[[ $(sed -n "s/^exit //p" "$LOG") == 3 ]]'
assert "the changed files are recorded" '[[ $(section changed) == *"M file"* && $(section changed) == *"?? test_new"* ]]'
assert "the output is recorded" '[[ $(section output) == "assertion failed: want 2 got 1" ]]'
assert "no temp file is left beside the log" '[[ $(find "$CREW/items/a1" -type f | wc -l) -eq 1 ]]'

echo "append"
mkdir -p "$WT/sub"
cr_in "$WT/sub" a1 false
assert "a second red run from a subdirectory is recorded" '[[ $RC -eq 0 ]]'
assert "changed paths stay relative to the worktree root" '[[ $(awk "/^red /{n++} n == 2" "$LOG" | sed -n "/^changed:$/,/^output:$/p") == *" M file"* ]] && ! grep -qF "../" "$LOG"'
assert "it appends a block rather than replacing the first" '[[ $(grep -c "^red " "$LOG") -eq 2 && $(grep -c "^exit 3$" "$LOG") -eq 1 && $(grep -c "^exit 1$" "$LOG") -eq 1 ]]'

echo "caps"
command rm -f "$LOG"
for i in $(seq 1 50); do echo "$i" >"$WT/extra$i"; done
cr a1 bash -c 'seq 1 100; exit 1'
assert "the printed tail is the last 30 lines" '[[ $(grep -cx "[0-9][0-9]*" <<<"$OUT") -eq 30 ]] && grep -qx 100 <<<"$OUT" && ! grep -qx 70 <<<"$OUT"'
assert "the recorded output is the last 40 lines" '[[ $(section output | wc -l) -eq 40 && $(section output | head -n 1) == 61 && $(section output | tail -n 1) == 100 ]]'
assert "the changed list is capped at 40 lines" '[[ $(section changed | wc -l) -eq 40 ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
