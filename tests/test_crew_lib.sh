#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
trap 'command rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

new_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

hash4() { printf %s "$1" | sha1sum | cut -c1-4; }

MAIN="$TMP_DIR/My Repo.Name"
new_repo "$MAIN"
MAIN=$(cd "$MAIN" && pwd -P)
mkdir -p "$MAIN/sub/dir"
git -C "$MAIN" worktree add -q -b w/1 "$MAIN/.claude/worktrees/w-1"
ln -s "$MAIN" "$TMP_DIR/link"

assert "main checkout resolves to itself" '[[ $(cd "$MAIN" && crew_main) == "$MAIN" ]]'
assert "a subdirectory resolves to the main checkout" '[[ $(cd "$MAIN/sub/dir" && crew_main) == "$MAIN" ]]'
assert "a linked worktree resolves to the main checkout" '[[ $(cd "$MAIN/.claude/worktrees/w-1" && crew_main) == "$MAIN" ]]'
assert "a symlinked path resolves to the real main checkout" '[[ $(cd "$TMP_DIR/link" && crew_main) == "$MAIN" ]]'
assert "an explicit dir argument is honoured" '[[ $(cd "$TMP_DIR" && crew_main "$MAIN/sub") == "$MAIN" ]]'
assert "outside a repo crew_main fails" '! (cd "$TMP_DIR" && crew_main >/dev/null 2>&1)'
assert "crew_dir is .claude/crew of the main checkout" '[[ $(cd "$MAIN/.claude/worktrees/w-1" && crew_dir) == "$MAIN/.claude/crew" ]]'

expected="my-repo-name-$(hash4 "$MAIN")"
assert "slug lowercases, replaces odd characters and appends the path hash" '[[ $(cd "$MAIN" && crew_slug) == "$expected" ]]'
assert "slug is the same from a worktree" '[[ $(cd "$MAIN/.claude/worktrees/w-1" && crew_slug) == "$expected" ]]'

DIGIT="$TMP_DIR/9lives"
new_repo "$DIGIT"
DIGIT=$(cd "$DIGIT" && pwd -P)
assert "slug gets an r- prefix when it does not start with a letter" '[[ $(cd "$DIGIT" && crew_slug) == "r-9lives-$(hash4 "$DIGIT")" ]]'

LONG="$TMP_DIR/a-very-long-repository-basename-indeed"
new_repo "$LONG"
LONG=$(cd "$LONG" && pwd -P)
slug=$(cd "$LONG" && crew_slug)
assert "slug base is cut to 21 characters" '[[ $slug == "a-very-long-repositor-$(hash4 "$LONG")" ]]'
assert "slug is at most 26 characters" '[[ ${#slug} -le 26 ]]'
assert "the longest agent name fits herdr's limit" '[[ "$slug-old99" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
