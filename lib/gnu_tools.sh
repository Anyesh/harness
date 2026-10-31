#!/usr/bin/env bash

# The installer and the hooks it deploys call sed -i, grep -P and date -d, which
# the BSD tools that ship with macOS reject, and crew-merge and crew-dagr lock
# with flock, which macOS lacks.
harness_require_gnu_tools() {
  local os="$1" tool line missing=() failed=0
  [[ "$os" == Darwin ]] || return 0
  for tool in sed grep date; do
    line=""
    IFS= read -r line < <("$tool" --version 2>&1) || true
    [[ "$line" == *GNU* && "$line" != *BSD* ]] || missing+=("$tool")
  done
  if ((${#missing[@]})); then
    echo "[harness] GNU tools are required, found non-GNU: ${missing[*]}" >&2
    echo "[harness] brew install coreutils gnu-sed grep, then put their libexec/gnubin dirs first on PATH" >&2
    failed=1
  fi
  if ! command -v flock >/dev/null; then
    echo "[harness] flock is required by the crew tools: brew install flock" >&2
    failed=1
  fi
  ((failed == 0)) || exit 1
}
