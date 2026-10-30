#!/usr/bin/env bash

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fetch_verified() {
  local url="$1" expected="$2" out="$3" actual
  if ! curl -fsSL --retry 3 -o "$out" "$url"; then
    rm -f "$out"
    log_warn "download failed: $url"
    return 1
  fi
  actual=$(sha256_file "$out")
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$out"
    log_warn "sha256 mismatch for $url (expected $expected, got $actual)"
    return 1
  fi
}
