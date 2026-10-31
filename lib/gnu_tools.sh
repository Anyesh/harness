#!/usr/bin/env bash

# The installer and the hooks it deploys call sed -i, grep -P and date -d, which
# the BSD tools that ship with macOS reject.
harness_require_gnu_tools() {
  local os="$1" tool line missing=()
  [[ "$os" == Darwin ]] || return 0
  for tool in sed grep date; do
    line=""
    IFS= read -r line < <("$tool" --version 2>&1) || true
    [[ "$line" == *GNU* && "$line" != *BSD* ]] || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) && return 0
  echo "[harness] GNU tools are required, found non-GNU: ${missing[*]}" >&2
  echo "[harness] brew install coreutils gnu-sed grep, then put their libexec/gnubin dirs first on PATH" >&2
  exit 1
}
