#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT="$REPO_ROOT/configs/claude-code/bin/crew-lint-waits"

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
trap 'command rm -rf "$TMP_DIR"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export WIKI_VAULT="${TMP_DIR}/vault"
unset HARNESS_WORK
unset CREW_MEM

REPO=$TMP_DIR/repo
git init -q -b main "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
mkdir -p "$REPO/tests" "$REPO/src" "$REPO/web/__tests__"
printf 'import time\n\ndef test_old():\n    time.sleep(5)\n' >"$REPO/tests/test_old.py"
printf 'time.sleep(1)\n' >"$REPO/src/app.py"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
BASE=$(git -C "$REPO" rev-parse HEAD)

OUT=
RC=0
lint() {
  RC=0
  OUT=$(cd "$REPO" && env CREW_PREFLIGHT_BASE="$BASE" "$@" "$LINT" 2>&1) || RC=$?
}
commit_all() {
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "item $1"
}
reset_item() { git -C "$REPO" reset -q --hard "$BASE"; }

echo "clean items"
printf 'def test_new(client):\n    assert client.get("/")\n' >"$REPO/tests/test_new.py"
printf 'time.sleep(2)\n' >>"$REPO/src/app.py"
commit_all clean
lint
assert "a sleep in a non-test file and an old one in a test pass" '[[ $RC -eq 0 && -z $OUT ]]'
reset_item

echo "patterns"
printf 'import asyncio, time\n\nasync def test_a():\n    await asyncio.sleep(1)\n\ndef test_b():\n    time.sleep(0.5)\n\ndef test_c(c):\n    c.get("/", timeout=30)\n' >"$REPO/tests/test_slow.py"
printf 'test("x", async () => {\n  await new Promise(r => setTimeout(r, 500));\n  await page.waitForTimeout(100);\n});\n' >"$REPO/web/__tests__/app.js"
printf 'package x\n\nfunc TestX(t *testing.T) {\n\ttime.Sleep(time.Second)\n}\n' >"$REPO/src/x_test.go"
printf '#!/bin/sh\nsleep 3\n' >"$REPO/tests/run_it.sh"
printf 'it("y", () => { setTimeout(done, 10) })\n' >"$REPO/src/y.spec.ts"
printf 'it("z", () => { setTimeout(done, 10) })\n' >"$REPO/src/z.test.tsx"
printf 'def test_w():\n    pass\n    time.sleep(1)\n' >"$REPO/src/test_w.py"
printf 'def test_v():\n    time.sleep(1)\n' >"$REPO/src/v_test.py"
commit_all slow
lint
assert "it fails" '[[ $RC -eq 1 ]]'
assert "python sleeps and numeric timeout= are named by file:line" '[[ $OUT == *"tests/test_slow.py:4:"* && $OUT == *"tests/test_slow.py:7:"* && $OUT == *"tests/test_slow.py:10:"* ]]'
assert "setTimeout, new Promise and waitForTimeout are named" '[[ $OUT == *"web/__tests__/app.js:2:"* && $OUT == *"web/__tests__/app.js:3:"* ]]'
assert "Go time.Sleep in *_test.go is named" '[[ $OUT == *"src/x_test.go:4:"* ]]'
assert "shell sleep under tests/ is named" '[[ $OUT == *"tests/run_it.sh:2:"* ]]'
assert "*.spec.* and *.test.* files are test files" '[[ $OUT == *"src/y.spec.ts:1:"* && $OUT == *"src/z.test.tsx:1:"* ]]'
assert "test_*.py and *_test.py are test files" '[[ $OUT == *"src/test_w.py:3:"* && $OUT == *"src/v_test.py:2:"* ]]'
assert "the old sleep in an existing test is not named" '[[ $OUT != *test_old.py* ]]'
assert "the line text is shown" '[[ $OUT == *"await asyncio.sleep(1)"* ]]'
reset_item

echo "only added lines"
printf 'import time\n\ndef test_old():\n    time.sleep(5)\n\ndef test_other():\n    assert True\n' >"$REPO/tests/test_old.py"
commit_all unrelated
lint
assert "an edit near an old sleep passes" '[[ $RC -eq 0 ]]'
printf 'def test_other():\n    assert True\n' >"$REPO/tests/test_old.py"
commit_all removed
lint
assert "removing a sleep passes" '[[ $RC -eq 0 ]]'
reset_item

echo "extra patterns"
mkdir -p "$WIKI_VAULT/wiki/projects/repo/crew"
printf 'wait_until_ready\\(\n# comment\n\nretry_for\\([0-9]+\n' >"$WIKI_VAULT/wiki/projects/repo/crew/wait-patterns"
printf 'def test_p():\n    wait_until_ready(db)\n    retry_for(30)\n    ok()\n' >"$REPO/tests/test_p.py"
commit_all extra
lint
assert "patterns in the store's wait-patterns are used" '[[ $RC -eq 1 && $OUT == *"tests/test_p.py:2:"* && $OUT == *"tests/test_p.py:3:"* ]]'
assert "a comment line in wait-patterns matches nothing" '[[ $OUT != *"tests/test_p.py:4:"* ]]'
mkdir -p "$TMP_DIR/mem"
printf 'only_here\\(\n' >"$TMP_DIR/mem/wait-patterns"
printf 'def test_q():\n    only_here(1)\n' >"$REPO/tests/test_q.py"
commit_all q
lint CREW_MEM="$TMP_DIR/mem"
assert "CREW_MEM names the pattern file's directory" '[[ $RC -eq 1 && $OUT == *"tests/test_q.py:2:"* && $OUT != *"tests/test_p.py"* ]]'
reset_item

echo "usage"
RC=0
OUT=$(cd "$REPO" && env -u CREW_PREFLIGHT_BASE "$LINT" 2>&1) || RC=$?
assert "without CREW_PREFLIGHT_BASE it fails and says so" '[[ $RC -eq 2 && $OUT == *CREW_PREFLIGHT_BASE* ]]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
