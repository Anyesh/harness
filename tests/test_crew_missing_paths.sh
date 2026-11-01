#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CMP="$REPO_ROOT/configs/claude-code/bin/crew-missing-paths"

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
run() {
  RC=0
  OUT=$("$@" 2>"$TMP/err") || RC=$?
  ERR=$(<"$TMP/err")
}
has() { grep -qxF -- "$1" <<<"$OUT"; }

CREW="$TMP/crew"
mkdir -p "$CREW/items/3" "$CREW/items/4" "$TMP/wt-parent"
cat >"$CREW/cargo-iso" <<EOF
#!/usr/bin/env bash
export CARGO_TARGET_DIR=\${CREW_TARGET_DIR:-$TMP/gone/target}/x
exec $TMP/stalehome/bin/tool "\$@"
EOF
printf 'Build with `%s` and keep %s here.\n' "$TMP/specmissing/a" "$TMP/crew" >"$CREW/items/3/spec.md"
printf 'nothing here\n' >"$CREW/items/4/spec.md"
for f in board.tsv board.tsv.bak rulings.md reflections.md plan.md watch-paths lead dagr-run dagr.log .sweep-seen; do
  printf 'see %s\n' "$TMP/skip-$f" >"$CREW/$f"
done
{
  printf '%s\n' 'Docs at https://example.com/foo/bar, config in $HOME/nothere and ~/nothere, branch w/1.'
  printf '%s\n' 'Probe /health and /v1/projects; pushes go to /nonexistent/crew-no-push.'
  printf 'The log ends in %s.\n' "$TMP/dots/missing"
  printf 'Targets: %s and %s and %s.\n' "$TMP/cut/x/\$(basename \"\$PWD\")" "$TMP/\$(date)" "$TMP/wt-parent/nope/w-<id>"
  printf 'Globs: %s and %s\n' "$TMP/globbed/*.log" "$TMP/braced/{a,b}"
  printf '%s\n' 'Built paths: ${CARGO_HOME}/etc/crew-notreal1, $(pwd)/etc/crew-notreal2, "$main"/etc/crew-notreal3, "${x}"/etc/crew-notreal4.'
  printf 'Quoted: dir="%s"\n' "$TMP/quoted/missing"
} >"$CREW/brief.md"
printf 'bin\0ary %s\n' "$TMP/binmissing" >"$CREW/blob"

echo "reported"
run "$CMP" "$CREW"
expected=$(printf 'missing: %s\n' "$TMP/braced/" "$TMP/cut/x/" "$TMP/dots/missing" "$TMP/globbed/" "$TMP/gone/target" "$TMP/stalehome/bin/tool" "$TMP/quoted/missing" "$TMP/specmissing/a" "$TMP/wt-parent/nope/" | LC_ALL=C sort)
assert "a stale path in an extra helper file is reported" 'has "missing: $TMP/stalehome/bin/tool"'
assert "a missing default inside \${VAR:-/path} is reported" 'has "missing: $TMP/gone/target"'
assert "a path in a backtick code span of a spec is reported" 'has "missing: $TMP/specmissing/a"'
assert "a path cut at \$ is checked at its last /" 'has "missing: $TMP/cut/x/" && ! grep -qF "$TMP/\$" <<<"$OUT"'
assert "a template like w-<id> is checked at its parent dir" 'has "missing: $TMP/wt-parent/nope/"'
assert "trailing dots are stripped" 'has "missing: $TMP/dots/missing"'
assert "the output is exactly the missing paths, sorted, with exit 0" '[[ $OUT == "$expected" && $RC -eq 0 && -z $ERR ]]'
assert "board, rulings, reflections, plan, watch-paths, lead, dagr and dot files are skipped" '! grep -q skip- <<<"$OUT"'
assert "URLs, \$var and ~ paths and missing first components are skipped" '! grep -qE "nothere|example|health|projects|nonexistent|w/1" <<<"$OUT"'
assert "paths after \${x}, \$(cmd) and a closing quote are skipped" '! grep -q crew-notreal <<<"$OUT"'
assert "a quoted absolute path is checked" 'has "missing: $TMP/quoted/missing"'
assert "binary files are skipped" '! grep -q binmissing <<<"$OUT"'

echo "edges"
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
printf 'see %s\n' "$TMP/nospec/missing" >"$EMPTY/brief.md"
run "$CMP" "$EMPTY"
assert "a crew without items/ is checked cleanly" '[[ $OUT == "missing: $TMP/nospec/missing" && $RC -eq 0 && -z $ERR ]]'
mkdir -p "$TMP/bare"
RC=0
OUT=$(sleep 10 | timeout 5 "$CMP" "$TMP/bare" 2>&1) || RC=$?
assert "a crew dir with no files prints nothing and never reads stdin" '[[ -z $OUT && $RC -eq 0 ]]'
run "$CMP" "$TMP/no-such-crew"
assert "a crew dir that does not exist is an error" '[[ $RC -ne 0 && -n $ERR ]]'

echo "default crew dir"
git init -q "$TMP/repo"
mkdir -p "$TMP/repo/.claude/crew" "$TMP/repo/sub"
printf 'see %s\n' "$TMP/repo-missing" >"$TMP/repo/.claude/crew/brief.md"
RC=0
OUT=$(cd "$TMP/repo/sub" && "$CMP" 2>&1) || RC=$?
assert "with no argument it checks the repo's crew dir" '[[ $OUT == "missing: $TMP/repo-missing" && $RC -eq 0 ]]'

if command -v zsh >/dev/null; then
  RC=0
  OUT=$(zsh -c '"$1" "$2"' zsh "$CMP" "$CREW" 2>&1) || RC=$?
  assert "it runs the same from zsh" '[[ $OUT == "$expected" && $RC -eq 0 ]]'
else
  echo "  SKIP  zsh not installed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
