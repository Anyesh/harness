#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILURES=0

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
