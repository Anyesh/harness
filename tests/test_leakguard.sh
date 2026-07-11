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

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "SKIP: gitleaks not installed"
  exit 0
fi

export LEAKGUARD_CONFIG="$REPO_ROOT/configs/leakguard/gitleaks.toml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOOKS_DIR="$TMP/hooks"
mkdir -p "$HOOKS_DIR"
cp "$REPO_ROOT/configs/leakguard/pre-commit" "$HOOKS_DIR/pre-commit"
chmod +x "$HOOKS_DIR/pre-commit"

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config core.hooksPath "$HOOKS_DIR"

echo "creds for haurka at 192.168.1.9" > "$REPO/leak.txt"
git -C "$REPO" add leak.txt
assert "pre-commit blocks staged leak" "! git -C '$REPO' commit -q -m x 2>/dev/null"

git -C "$REPO" rm -q --cached leak.txt
echo "hello" > "$REPO/clean.txt"
git -C "$REPO" add clean.txt
assert "pre-commit passes clean change" "git -C '$REPO' commit -q -m clean 2>/dev/null"

echo "note: box is haurka" > "$REPO/leak2.txt"
git -C "$REPO" add leak2.txt
assert "LEAKGUARD_SKIP bypasses" "LEAKGUARD_SKIP=1 git -C '$REPO' commit -q -m skip 2>/dev/null"

printf '#!/bin/sh\ntouch "%s/local_ran"\nexit 0\n' "$TMP" > "$REPO/.git/hooks/pre-commit"
chmod +x "$REPO/.git/hooks/pre-commit"
echo "more" >> "$REPO/clean.txt"
git -C "$REPO" add clean.txt
git -C "$REPO" commit -q -m chain 2>/dev/null
assert "dispatcher chains repo-local hook" "[ -f '$TMP/local_ran' ]"

PUB="$TMP/pub"
mkdir -p "$PUB/dist" "$PUB/pkg"
echo "secrets under /mnt/data/keys" > "$PUB/pkg/bad.txt"
tar -czf "$PUB/dist/pkg-0.1.tar.gz" -C "$PUB" pkg
GUARD="$REPO_ROOT/configs/shared/hooks/publish-leak-guard.sh"
assert "publish guard blocks poisoned sdist" \
  "! echo '{\"tool_input\":{\"command\":\"cd $PUB && uv publish\"},\"cwd\":\"/\"}' | bash '$GUARD' >/dev/null 2>&1"

CLEANPUB="$TMP/cleanpub"
mkdir -p "$CLEANPUB/dist" "$CLEANPUB/pkg"
echo "nothing personal" > "$CLEANPUB/pkg/ok.txt"
tar -czf "$CLEANPUB/dist/pkg-0.1.tar.gz" -C "$CLEANPUB" pkg
assert "publish guard passes clean sdist" \
  "echo '{\"tool_input\":{\"command\":\"cd $CLEANPUB && uv publish\"},\"cwd\":\"/\"}' | bash '$GUARD' >/dev/null 2>&1"

assert "publish guard ignores non-publish commands" \
  "echo '{\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"$PUB\"}' | bash '$GUARD' >/dev/null 2>&1"

echo x > "$PUB/pkg/.scope.md"
tar -czf "$PUB/dist/pkg-0.2.tar.gz" -C "$PUB" pkg
assert "publish guard blocks forbidden filenames" \
  "! echo '{\"tool_input\":{\"command\":\"cd $PUB && twine upload dist/*\"},\"cwd\":\"/\"}' | bash '$GUARD' >/dev/null 2>&1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
