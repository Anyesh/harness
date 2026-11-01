#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

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

TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'command rm -rf "$TMP"' EXIT

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# shellcheck disable=SC2012
inode_of() { ls -di "$1" | awk '{print $1}'; }
no_temps() { [[ -z "$(find "$@" -maxdepth 1 -name '.*.??????' -print)" ]]; }

RUN="$TMP/running"
mkdir -p "$RUN"
printf '#!/usr/bin/env bash\necho one\nsleep 2\necho two\n' >"$RUN/script"
chmod +x "$RUN/script"
{
  printf '#!/usr/bin/env bash\n'
  for _ in $(seq 40); do printf 'echo replaced; exit 3\n'; done
} >"$RUN/new"
SCRIPT_RC=0
"$RUN/script" >"$RUN/out" 2>&1 &
SCRIPT_PID=$!
sleep 0.5
atomic_copy "$RUN/new" "$RUN/script"
wait "$SCRIPT_PID" || SCRIPT_RC=$?
assert "a script replaced mid-run finishes with its original output" \
  "[ $SCRIPT_RC -eq 0 ] && [ \"\$(cat '$RUN/out')\" = \"\$(printf 'one\ntwo')\" ]"
assert "the replaced script holds the new content" "cmp -s '$RUN/new' '$RUN/script'"

EX="$TMP/existing"
mkdir -p "$EX"
printf 'old\n' >"$EX/dest"
chmod 0640 "$EX/dest"
printf 'new\n' >"$EX/src"
chmod 0755 "$EX/src"
before=$(inode_of "$EX/dest")
atomic_copy "$EX/src" "$EX/dest"
assert "a replaced file gets a new inode" "[ \"$before\" != \"\$(inode_of '$EX/dest')\" ]"
assert "a replaced file keeps its mode" "[ \"\$(mode_of '$EX/dest')\" = 640 ]"
assert "a replaced file has the new content" "cmp -s '$EX/src' '$EX/dest'"
assert "no temp is left beside a replaced file" "no_temps '$EX'"

NEW="$TMP/new"
mkdir -p "$NEW"
printf 'x\n' >"$NEW/src"
chmod 0666 "$NEW/src"
(
  umask 027
  cp "$NEW/src" "$NEW/plain"
  atomic_copy "$NEW/src" "$NEW/sub/dir/atomic"
  atomic_copy "$NEW/src" "$NEW/exec" executable
)
assert "a new file gets the mode plain cp gives" \
  "[ \"\$(mode_of '$NEW/sub/dir/atomic')\" = \"\$(mode_of '$NEW/plain')\" ]"
assert "executable sets +x on a new file" "[ -x '$NEW/exec' ]"

PR="$TMP/preserve"
mkdir -p "$PR"
printf 'backup\n' >"$PR/backup"
chmod 0755 "$PR/backup"
printf 'deployed\n' >"$PR/dest"
chmod 0644 "$PR/dest"
atomic_copy "$PR/backup" "$PR/dest" preserve
assert "preserve restores the source's mode" "[ \"\$(mode_of '$PR/dest')\" = 755 ]"
assert "preserve restores the source's content" "cmp -s '$PR/backup' '$PR/dest'"

LN="$TMP/links"
mkdir -p "$LN/a" "$LN/b"
printf 'old\n' >"$LN/b/real"
ln -s ../b/real "$LN/a/link"
ln -s link "$LN/a/hop"
printf 'via link\n' >"$LN/src"
(cd / && atomic_copy "$LN/src" "$LN/a/hop")
assert "a symlinked dest stays a symlink" "[ -L '$LN/a/link' ] && [ -L '$LN/a/hop' ]"
assert "a relative link resolves against its own directory" "cmp -s '$LN/src' '$LN/b/real'"
assert "no temp is left in either directory of a link" "no_temps '$LN/a' '$LN/b'"

FA="$TMP/fail"
mkdir -p "$FA"
printf 'keep\n' >"$FA/dest"
FA_RC=0
atomic_copy "$FA/missing" "$FA/dest" 2>/dev/null || FA_RC=$?
NEW_RC=0
atomic_copy "$FA/missing" "$FA/fresh" executable 2>/dev/null || NEW_RC=$?
assert "a missing source fails" "[ $FA_RC -ne 0 ] && [ $NEW_RC -ne 0 ]"
assert "a failed copy leaves the dest untouched" "[ \"\$(cat '$FA/dest')\" = keep ] && [ ! -e '$FA/fresh' ]"
assert "a failed copy leaves no temp" "no_temps '$FA'"

CY="$TMP/cycle"
mkdir -p "$CY"
ln -s b "$CY/a"
ln -s a "$CY/b"
printf 'x\n' >"$TMP/cycle-src"
CY_RC=0
# shellcheck disable=SC2016
timeout 10 bash -c 'source "$1/lib/common.sh"; atomic_copy "$2" "$3"' _ "$REPO_ROOT" "$TMP/cycle-src" "$CY/a" \
  2>"$TMP/cycle-err" || CY_RC=$?
assert "a cyclic link fails without hanging" "[ $CY_RC -ne 0 ] && [ $CY_RC -ne 124 ]"
assert "a cyclic link reports an error" "[ -s '$TMP/cycle-err' ]"
assert "a cyclic link leaves no temp and keeps both links" "no_temps '$CY' && [ -L '$CY/a' ] && [ -L '$CY/b' ]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
