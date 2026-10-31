#!/usr/bin/env bash
# Sourced by install.sh before anything else, so it must parse under bash 3.2.

HARNESS_BASH_CANDIDATES=(/opt/homebrew/bin/bash /usr/local/bin/bash)

harness_bash_major() {
  "$1" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null
}

# Args: current major version, script, then the script's arguments. Returns
# when the major is 4 or newer; otherwise execs the script under the first
# bash 4+ found, or exits 1.
harness_ensure_modern_bash() {
  local major="$1" script="$2" candidate found=""
  shift 2
  [ "$major" -ge 4 ] && return 0
  for candidate in "${HARNESS_BASH_CANDIDATES[@]}" "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if [ "$(harness_bash_major "$candidate")" -ge 4 ] 2>/dev/null; then
      found="$candidate"
      break
    fi
  done
  if [ -z "$found" ]; then
    echo "[harness] bash 4 or newer is required (this is bash $major); install it with: brew install bash" >&2
    exit 1
  fi
  exec "$found" "$script" ${1+"$@"}
}
