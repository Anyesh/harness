#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILURES=0

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH
unset HARNESS_WORK WIKI_VAULT
while read -r name; do
  [[ "$name" == GIT_CONFIG_* ]] && unset "$name"
done < <(compgen -e)

CREW_RUNS_DIR=$(mktemp -d)
export CREW_RUNS_DIR
trap 'rm -rf "$CREW_RUNS_DIR"' EXIT

for test_file in "$SCRIPT_DIR"/test_*.sh; do
  echo "--- Running: $(basename "$test_file") ---"
  if bash "$test_file"; then
    echo ""
  else
    FAILURES=$((FAILURES + 1))
    echo ""
  fi
done

if [[ $FAILURES -eq 0 ]]; then
  echo "All tests passed."
else
  echo "$FAILURES test file(s) failed."
  exit 1
fi
