#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/worktree-sweep.sh"

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
trap 'rm -rf "$TMP_DIR"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

R="$TMP_DIR/repo"
WT="$TMP_DIR/wt"
mkdir -p "$R" "$WT"
git init -q -b main "$R"
git -C "$R" commit -q --allow-empty -m "base"

g() { git -C "$R" "$@"; }
commit_file() { echo "$2" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "$3"; }
age() {
  local wt="$1" gd
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  find "$gd" -maxdepth 2 \( -name HEAD -o -path '*/logs/HEAD' \) -exec touch -d '3 days ago' {} +
}

g worktree add -q -b merged "$WT/merged"
commit_file "$WT/merged" m.txt "merged work"
g merge -q --ff-only merged
age "$WT/merged"

g worktree add -q -b unlanded "$WT/unlanded"
commit_file "$WT/unlanded" u.txt "unlanded work"
age "$WT/unlanded"

g worktree add -q --detach "$WT/detached"
commit_file "$WT/detached" d.txt "detached work"
age "$WT/detached"

g worktree add -q -b dirty "$WT/dirty"
echo tracked > "$WT/dirty/t.txt"; git -C "$WT/dirty" add t.txt; git -C "$WT/dirty" commit -q -m "dirty base"
g merge -q --ff-only dirty
echo edited > "$WT/dirty/t.txt"
echo new > "$WT/dirty/new.txt"
mkdir -p "$WT/dirty/.venv"; echo v > "$WT/dirty/.venv/lib.txt"
age "$WT/dirty"
touch -d '3 days ago' "$WT/dirty/t.txt" "$WT/dirty/new.txt" "$WT/dirty/.venv/lib.txt"

g worktree add -q -b recent "$WT/recent"

g worktree add -q -b locked "$WT/locked"
age "$WT/locked"
g worktree lock "$WT/locked"

g worktree add -q -b squashed "$WT/squashed"
commit_file "$WT/squashed" s.txt "squash subject"
age "$WT/squashed"
g checkout -q main
echo other > "$R/s.txt"; echo more >> "$R/s.txt"
g add s.txt; g commit -q -m "squash subject"

snapshot() { g worktree list --porcelain | grep -c '^worktree ' ; g branch --format='%(refname:short)' | sort | tr '\n' ' '; }

BEFORE=$(snapshot)
OUT=$(bash "$HOOK" --dry-run --repo "$R")
assert "dry-run changes nothing" '[[ "$(snapshot)" == "$BEFORE" && -d "$WT/merged" ]]'
assert "dry-run reports what it would do" 'grep -q "would remove $WT/merged" <<< "$OUT" && grep -q "dry run" <<< "$OUT"'

OUT=$(bash "$HOOK" --repo "$R")

assert "merged idle worktree is removed" '[[ ! -d "$WT/merged" ]]'
assert "merged branch is deleted" '! g rev-parse --verify -q refs/heads/merged >/dev/null'
assert "unlanded worktree is removed" '[[ ! -d "$WT/unlanded" ]]'
assert "unlanded branch is kept" 'g rev-parse --verify -q refs/heads/unlanded >/dev/null'
assert "detached unlanded worktree is removed" '[[ ! -d "$WT/detached" ]]'
assert "detached commits land on a salvage branch" 'g rev-parse --verify -q refs/heads/salvage/detached >/dev/null'
assert "squash-landed worktree is removed with its branch" '[[ ! -d "$WT/squashed" ]] && ! g rev-parse --verify -q refs/heads/squashed >/dev/null'
assert "recently active worktree is skipped" '[[ -d "$WT/recent" ]] && grep -q "skipped $WT/recent (active" <<< "$OUT"'
assert "locked worktree is skipped" '[[ -d "$WT/locked" ]] && grep -q "skipped $WT/locked (locked)" <<< "$OUT"'

SALV=$(echo "$R"/.git/worktree-salvage/*/dirty)
assert "dirty worktree is removed" '[[ ! -d "$WT/dirty" ]]'
assert "tracked changes are salvaged as a diff" 'grep -q edited "$SALV/tracked.diff"'
assert "untracked files are salvaged" 'tar -tzf "$SALV/untracked.tar.gz" | grep -q new.txt'
assert "venv is excluded from the salvage" '! tar -tzf "$SALV/untracked.tar.gz" | grep -q .venv'
assert "salvage records info" 'grep -q "^branch: dirty" "$SALV/info.txt"'
assert "summary line counts the sweep" 'grep -qE "^worktree-sweep: removed 5, kept branches 2, salvaged 1, skipped 2$" <<< "$OUT"'

QOUT=$(bash "$HOOK" --quiet --repo "$R")
assert "quiet prints nothing when nothing was removed" '[[ -z "$QOUT" ]]'

NOREPO=$(cd "$TMP_DIR" && bash "$HOOK")
assert "outside a git repo it exits quietly" '[[ -z "$NOREPO" ]]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
