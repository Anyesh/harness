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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_BASH="$BASH"

# Args: path, major version it reports. The fake answers the version probe and
# otherwise records the argv it was exec'd with.
fake_bash() {
  local path="$1" major="$2"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
#!/bin/sh
if [ "\$1" = -c ]; then echo $major; exit 0; fi
printf '%s\n' "$path" "\$@" > "$TMP/exec.log"
EOF
  chmod +x "$path"
}

# Args: PATH for the call, candidate list, current major, then the script args.
ensure() {
  local path="$1" candidates="$2" major="$3"
  shift 3
  : >"$TMP/exec.log"
  PATH="$path" REPO_ROOT="$REPO_ROOT" "$REAL_BASH" -c '
    set -euo pipefail
    source "$REPO_ROOT/lib/modern_bash.sh"
    HARNESS_BASH_CANDIDATES=($1)
    shift
    harness_ensure_modern_bash "$@"
    echo "returned"' _ "$candidates" "$major" "$@"
}

echo ""
echo "=== harness_ensure_modern_bash ==="

fake_bash "$TMP/old/bash" 3
fake_bash "$TMP/brew/bash" 5
fake_bash "$TMP/local/bash" 4
fake_bash "$TMP/path5/bash" 5

out=$(ensure "$TMP/old" "$TMP/brew/bash" 5 /x/install.sh --dry-run)
assert "bash 4+ returns without exec" '[[ "$out" == returned && ! -s $TMP/exec.log ]]'

rc=0
out=$(ensure "$TMP/old" "$TMP/brew/bash $TMP/local/bash" 3 /x/install.sh --only "a b" "") || rc=$?
assert "bash 3 execs the first candidate with the script and every argument" \
  '[[ $rc -eq 0 && "$out" != *returned* && "$(cat "$TMP/exec.log")" == "$(printf "%s\n" "$TMP/brew/bash" /x/install.sh --only "a b" "")" ]]'

out=$(ensure "$TMP/old" "$TMP/missing/bash $TMP/local/bash" 3 /x/install.sh)
assert "a missing candidate is skipped" '[[ "$(head -1 "$TMP/exec.log")" == "$TMP/local/bash" ]]'

out=$(ensure "$TMP/old" "$TMP/old/bash $TMP/local/bash" 3 /x/install.sh)
assert "a candidate that is itself bash 3 is skipped" '[[ "$(head -1 "$TMP/exec.log")" == "$TMP/local/bash" ]]'

out=$(ensure "$TMP/path5" "$TMP/missing/bash" 3 /x/install.sh status)
assert "bash on PATH is tried after the fixed candidates" \
  '[[ "$(cat "$TMP/exec.log")" == "$(printf "%s\n" "$TMP/path5/bash" /x/install.sh status)" ]]'

out=$(ensure "$TMP/path5" "$TMP/missing/bash" 3 /x/install.sh)
assert "no arguments are passed when none were given" \
  '[[ "$(cat "$TMP/exec.log")" == "$(printf "%s\n" "$TMP/path5/bash" /x/install.sh)" ]]'

rc=0
out=$(ensure "$TMP/old" "$TMP/missing/bash $TMP/old/bash" 3 /x/install.sh 2>&1) || rc=$?
assert "no bash 4 anywhere: exits non-zero with one line naming brew install bash" \
  '[[ $rc -ne 0 && "$out" != *returned* && $(wc -l <<<"$out") -eq 1 && "$out" == *"brew install bash"* && ! -s $TMP/exec.log ]]'

echo ""
echo "=== install.sh under a real bash 3 ==="

OLD_BASH=""
for b in /bin/bash /usr/bin/bash; do
  if [[ -x "$b" && "$("$b" -c 'echo "${BASH_VERSINFO[0]}"')" -lt 4 ]]; then
    OLD_BASH="$b"
    break
  fi
done
if [[ -n "$OLD_BASH" ]]; then
  mkdir -p "$TMP/home/.local/bin"
  printf '#!/bin/sh\nexit 0\n' >"$TMP/home/.local/bin/claude"
  chmod +x "$TMP/home/.local/bin/claude"
  for form in path relative; do
    rc=0
    if [[ "$form" == path ]]; then
      out=$(HOME="$TMP/home" HARNESS_ENV="$TMP/home/.harness.env" "$OLD_BASH" "$REPO_ROOT/install.sh" --dry-run --no-plugins --only claude 2>&1) || rc=$?
    else
      out=$(cd "$REPO_ROOT" && HOME="$TMP/home" HARNESS_ENV="$TMP/home/.harness.env" "$OLD_BASH" install.sh --dry-run --no-plugins --only claude 2>&1) || rc=$?
    fi
    assert "$OLD_BASH install.sh --dry-run --only claude ($form) re-execs and succeeds" \
      '[[ $rc -eq 0 ]] && ! grep -qE "invalid option|unbound variable" <<<"$out"'
  done
else
  echo "SKIP: no bash older than 4 on this machine"
fi

echo ""
echo "Modern bash: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
