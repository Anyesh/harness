#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIN="$REPO_ROOT/scripts/pin-toolchain.sh"

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

TARGETS=(x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin)
GO_PLATFORMS=(linux-amd64 linux-arm64 darwin-amd64 darwin-arm64)
digest() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

FIXTURES="$TMP/fixtures"
mkdir -p "$FIXTURES" "$TMP/bin"
{
  for t in "${TARGETS[@]}"; do
    for c in rustc cargo rust-std; do
      printf '[pkg.%s.target.%s]\nxz_url = "https://static.rust-lang.org/dist/2027-01-01/%s-1.97.0-%s.tar.xz"\nxz_hash = "%s"\n' \
        "$c" "$t" "$c" "$t" "$(digest "$c-$t")"
      printf '%s  %s-1.97.0-%s.tar.xz\n' "$(digest "$c-$t")" "$c" "$t" >"$FIXTURES/$c-1.97.0-$t.tar.xz.sha256"
    done
  done
} >"$FIXTURES/channel-rust-1.97.0.toml"
files=""
for p in "${GO_PLATFORMS[@]}"; do
  files+="${files:+,}{\"filename\":\"go1.28.0.$p.tar.gz\",\"kind\":\"archive\",\"sha256\":\"$(digest "go-$p")\"}"
done
printf '[{"version":"go1.28.0","files":[%s]}]\n' "$files" >"$FIXTURES/go-dl.json"

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  https://go.dev/dl/*) cat "$FIXTURES/go-dl.json" ;;
  *) cat "$FIXTURES/${url##*/}" 2>/dev/null || exit 22 ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export FIXTURES PATH="$TMP/bin:$PATH"

reset_module() {
  cp "$REPO_ROOT/modules/herdr.sh" "$TMP/herdr.sh"
}
pin() {
  rc=0
  out=$(HERDR_MODULE="$TMP/herdr.sh" "$PIN" "$@" 2>&1) || rc=$?
}
pinned() {
  (
    source "$TMP/herdr.sh"
    "$@"
  )
}

echo "=== rust ==="

reset_module
pin rust 1.97.0
assert "rust pin succeeds" '[[ $rc -eq 0 ]]'
assert "rust pin rewrites the version" 'grep -qx "HERDR_RUST_VERSION=\"1.97.0\"" "$TMP/herdr.sh"'
all_match=yes
for t in "${TARGETS[@]}"; do
  for c in rustc cargo rust-std; do
    [[ "$(pinned herdr_rust_sha256 "$c" "$t")" == "$(digest "$c-$t")" ]] || all_match=no
  done
done
assert "rust pin rewrites all twelve digests" '[[ $all_match == yes ]]'
assert "rust pin names the new channel manifest" 'grep -q "channel-rust-1.97.0.toml" "$TMP/herdr.sh"'
assert "rust pin changes only the rust lines" \
  '! diff "$REPO_ROOT/modules/herdr.sh" "$TMP/herdr.sh" | grep "^[<>]" | grep -qvE "HERDR_RUST_VERSION=|-(unknown-linux-gnu|apple-darwin)\"\) echo|channel-rust-"'

reset_module
printf '%s  x\n' "$(digest other)" >"$FIXTURES/cargo-1.97.0-x86_64-apple-darwin.tar.xz.sha256"
pin rust 1.97.0
assert "rust digest disagreeing with the manifest fails" '[[ $rc -ne 0 ]] && grep -q "cargo-1.97.0-x86_64-apple-darwin" <<<"$out"'
assert "rust digest disagreeing with the manifest changes nothing" 'cmp -s "$TMP/herdr.sh" "$REPO_ROOT/modules/herdr.sh"'

pin rust 1.98.0
assert "unpublished rust version fails and changes nothing" '[[ $rc -ne 0 ]] && cmp -s "$TMP/herdr.sh" "$REPO_ROOT/modules/herdr.sh"'

echo "=== go ==="

reset_module
pin go 1.28.0
assert "go pin succeeds" '[[ $rc -eq 0 ]]'
assert "go pin rewrites the version" 'grep -qx "HERDR_GO_VERSION=\"1.28.0\"" "$TMP/herdr.sh"'
all_match=yes
for p in "${GO_PLATFORMS[@]}"; do
  [[ "$(pinned herdr_go_sha256 "$p")" == "$(digest "go-$p")" ]] || all_match=no
done
assert "go pin rewrites all four digests" '[[ $all_match == yes ]]'
assert "go pin leaves the herdr binary digests alone" \
  '[[ "$(pinned herdr_asset_sha256 linux-x86_64)" == "$(source "$REPO_ROOT/modules/herdr.sh" && herdr_asset_sha256 linux-x86_64)" ]]'

reset_module
pin go 1.29.0
assert "unpublished go version fails and changes nothing" '[[ $rc -ne 0 ]] && cmp -s "$TMP/herdr.sh" "$REPO_ROOT/modules/herdr.sh"'

pin ruby 3.0
assert "unknown toolchain is a usage error" '[[ $rc -ne 0 ]] && grep -qi "usage" <<<"$out"'

echo ""
echo "pin-toolchain: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
