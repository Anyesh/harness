#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: pin-toolchain.sh rust|go <version>

Pins the Rust or Go toolchain that modules/herdr.sh provisions for herdr plugin
builds: rewrites HERDR_RUST_VERSION or HERDR_GO_VERSION and every per-platform
sha256 beside it. Rust digests come from each component's .sha256 file and
must match channel-rust-<version>.toml; Go digests come from go.dev/dl.
Nothing is written unless every digest is found.
EOF
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="${HERDR_MODULE:-$REPO_ROOT/modules/herdr.sh}"
RUST_DIST=https://static.rust-lang.org/dist

rust_digests() {
  local version="$1" manifest target component name sha
  manifest=$(curl -fsSL "$RUST_DIST/channel-rust-$version.toml")
  for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
    for component in rustc cargo rust-std; do
      name="$component-$version-$target.tar.xz"
      sha=$(curl -fsSL "$RUST_DIST/$name.sha256" | cut -d' ' -f1)
      if ! grep -A1 -E "^xz_url = \"$RUST_DIST/[^\"]*/$name\"$" <<<"$manifest" | grep -qx "xz_hash = \"$sha\""; then
        echo "$name: its .sha256 ($sha) does not match channel-rust-$version.toml" >&2
        return 1
      fi
      printf '"%s %s"\t%s\n' "$component" "$target" "$sha"
    done
  done
}

go_digests() {
  local version="$1" releases platform sha
  releases=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all')
  for platform in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
    sha=$(jq -r --arg v "go$version" --arg f "go$version.$platform.tar.gz" \
      '.[] | select(.version == $v) | .files[] | select(.filename == $f) | .sha256' <<<"$releases")
    if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      echo "go$version has no published $platform archive" >&2
      return 1
    fi
    printf '%s\t%s\n' "$platform" "$sha"
  done
}

rewrite_module() {
  local var="$1" version="$2" digests="$3"
  awk -F'\t' -v var="$var" -v version="$version" -v want="$(wc -l <"$digests")" '
    NR == FNR { sha[$1] = $2; next }
    index($0, var "=\"") == 1 { print var "=\"" version "\""; seen_var = 1; next }
    {
      line = $0
      match(line, /^[[:space:]]*/)
      indent = substr(line, 1, RLENGTH)
      rest = substr(line, RLENGTH + 1)
      p = index(rest, ") echo ")
      if (p > 0 && (substr(rest, 1, p - 1) in sha)) {
        key = substr(rest, 1, p - 1)
        print indent key ") echo " sha[key] " ;;"
        replaced[key] = 1
        next
      }
      if (var == "HERDR_RUST_VERSION") gsub(/channel-rust-[0-9.]+\.toml/, "channel-rust-" version ".toml", line)
      print line
    }
    END {
      n = 0
      for (k in replaced) n++
      if (!seen_var || n != want) exit 1
    }
  ' "$digests" "$MODULE"
}

main() {
  [[ $# -eq 2 ]] || { usage >&2; exit 2; }
  local tool="$1" version="$2" var
  DIGESTS="" REWRITTEN=""
  trap 'rm -f "$DIGESTS" "$REWRITTEN"' EXIT
  DIGESTS=$(mktemp)
  REWRITTEN=$(mktemp)
  case "$tool" in
    rust) var=HERDR_RUST_VERSION; rust_digests "$version" >"$DIGESTS" ;;
    go) var=HERDR_GO_VERSION; go_digests "$version" >"$DIGESTS" ;;
    *) usage >&2; exit 2 ;;
  esac
  if ! rewrite_module "$var" "$version" "$DIGESTS" >"$REWRITTEN"; then
    echo "${MODULE#"$REPO_ROOT/"}: could not find $var and every $tool digest line to rewrite" >&2
    exit 1
  fi
  cat "$REWRITTEN" >"$MODULE"
  echo "pinned $tool $version in ${MODULE#"$REPO_ROOT/"}; now run bash tests/test_herdr_module.sh"
}

main "$@"
