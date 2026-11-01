#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CCB="$REPO_ROOT/configs/claude-code/bin/crew-clean-build"

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
    printf '        out: %s\n        err: %s\n' "${OUT//$'\n'/$'\n             '}" "${ERR//$'\n'/$'\n             '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'command rm -rf "$TMP"' EXIT

OUT=
ERR=
RC=0
RUN_DIR=
run() {
  RC=0
  OUT=$(cd "$RUN_DIR" && env HOME="$TMP/home" CREW_RUNS_DIR="$TMP/runs" "$@" 2>"$TMP/err") || RC=$?
  ERR=$(<"$TMP/err")
}

new_repo() {
  git init -q "$1"
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  mkdir -p "$1/.claude/crew/items"
}

build_dir() {
  mkdir -p "$1/.claude/crew/items/$2"
  printf '%s\n' "$3" >"$1/.claude/crew/items/$2/build-dir"
}

filled() {
  mkdir -p "$1/debug"
  : >"$1/debug/out"
}

REPO="$TMP/repo"
new_repo "$REPO"
mkdir -p "$TMP/home" "$TMP/runs"
RUN_DIR=$REPO

echo "deletes"
filled "$TMP/targets/w-1"
build_dir "$REPO" 1 "$TMP/targets/w-1"
run "$CCB" 1
assert "a w-<id> build dir is deleted and named" '[[ $RC -eq 0 && ! -e $TMP/targets/w-1 && $OUT == "removed $TMP/targets/w-1" ]]'
filled "$TMP/targets/2"
build_dir "$REPO" 2 "$TMP/targets/2"
run "$CCB" 2
assert "a build dir named for the bare id is deleted" '[[ $RC -eq 0 && ! -e $TMP/targets/2 ]]'
run "$CCB" 7
assert "an item without a build-dir file does nothing" '[[ $RC -eq 0 && -z $OUT && -z $ERR ]]'

echo "refuses"
filled "$TMP/data/1/shared"
build_dir "$REPO" 1 "$TMP/data/1/shared"
run "$CCB" 1
assert "a dir whose last component is not the id is refused" '[[ $RC -eq 1 && -d $TMP/data/1/shared ]] && grep -q "last component" <<<"$ERR"'
build_dir "$REPO" 1 "w-1"
mkdir -p "$REPO/w-1"
run "$CCB" 1
assert "a relative build-dir is refused" '[[ $RC -eq 1 && -d $REPO/w-1 ]] && grep -q "not absolute" <<<"$ERR"'
rmdir "$REPO/w-1"

filled "$TMP/w-1"
mkdir -p "$TMP/links"
ln -s "$TMP/w-1" "$TMP/links/w-1"
for raw in "$TMP/w-1" "$TMP/w-1/sub/.." "$TMP/links/w-1"; do
  build_dir "$REPO" 1 "$raw"
  RC=0
  OUT=$(cd "$REPO" && env HOME="$TMP/w-1" CREW_RUNS_DIR="$TMP/runs" "$CCB" 1 2>"$TMP/err") || RC=$?
  ERR=$(<"$TMP/err")
  assert "HOME is refused when named as $raw" '[[ $RC -eq 1 && -f $TMP/w-1/debug/out ]] && grep -q " is home " <<<"$ERR"'
done

MAIN1="$TMP/m/w-1"
new_repo "$MAIN1"
build_dir "$MAIN1" 1 "$MAIN1"
RUN_DIR=$MAIN1
run "$CCB" 1
RUN_DIR=$REPO
assert "the main checkout is refused" '[[ $RC -eq 1 && -d $MAIN1/.git ]] && grep -q "the main checkout" <<<"$ERR"'

mkdir -p "$TMP/r/w-1/runs"
build_dir "$REPO" 1 "$TMP/r/w-1"
RC=0
OUT=$(cd "$REPO" && env HOME="$TMP/home" CREW_RUNS_DIR="$TMP/r/w-1/runs" "$CCB" 1 2>"$TMP/err") || RC=$?
ERR=$(<"$TMP/err")
assert "a parent of the runs dir is refused" '[[ $RC -eq 1 && -d $TMP/r/w-1/runs ]] && grep -q "the runs dir" <<<"$ERR"'

git -C "$REPO" worktree add -q -b w/9 "$TMP/outside-wt"
filled "$TMP/outside-wt/w-1"
build_dir "$REPO" 1 "$TMP/outside-wt/w-1"
run "$CCB" 1
assert "a dir inside a worktree outside the main checkout is refused" '[[ $RC -eq 1 && -f $TMP/outside-wt/w-1/debug/out ]] && grep -q "inside worktree $TMP/outside-wt" <<<"$ERR"'

git -C "$REPO" worktree add -q -b w/6 "$TMP/ext/w-6/wt"
build_dir "$REPO" 6 "$TMP/ext/w-6"
run "$CCB" 6
assert "a dir holding a worktree is refused" '[[ $RC -eq 1 && -d $TMP/ext/w-6/wt ]] && grep -q "worktree $TMP/ext/w-6/wt" <<<"$ERR"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
