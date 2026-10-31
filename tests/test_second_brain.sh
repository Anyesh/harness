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
ISO_UTC='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z '

echo ""
echo "=== sb-sync.sh ==="

# BSD date has no -I, so this stub refuses it the way macOS does.
mkdir -p "$TMP/bsd-bin"
REAL_DATE=$(command -v date)
cat >"$TMP/bsd-bin/date" <<EOF
#!/bin/sh
case "\$1" in -I*) echo "date: illegal option -- I" >&2; exit 1 ;; esac
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$TMP/bsd-bin/date"

H="$TMP/sync-nosb"
mkdir -p "$H"
rc=0
out=$(HOME="$H" PATH="$TMP/bsd-bin:$PATH" sh "$REPO_ROOT/configs/second-brain/sb-sync.sh" 2>&1) || rc=$?
assert "missing sb: exits 1 with a UTC timestamp under BSD date" '[[ $rc -eq 1 ]] && grep -Eq "${ISO_UTC}sb binary missing" <<<"$out"'

H="$TMP/sync-nopeers"
mkdir -p "$H/.cargo/bin"
printf '#!/bin/sh\nexit 0\n' >"$H/.cargo/bin/sb"
chmod +x "$H/.cargo/bin/sb"
rc=0
out=$(HOME="$H" PATH="$TMP/bsd-bin:$PATH" sh "$REPO_ROOT/configs/second-brain/sb-sync.sh" 2>&1) || rc=$?
assert "no peers file: exits 0 with a UTC timestamp under BSD date" '[[ $rc -eq 0 ]] && grep -Eq "${ISO_UTC}no peers file" <<<"$out"'

echo ""
echo "Second-brain: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
