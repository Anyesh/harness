#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hook-blocks.sh [--days N] [--samples N] [--log FILE]

Summarises the guard block log written by configs/shared/hooks/log-block.sh:
blocks per hook over the last N days (default 7), busiest first, with the most
recent blocked commands or files. Read the samples for false positives.
EOF
}

LOG="${HARNESS_BLOCK_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/harness/hook-blocks.jsonl}"
DAYS=7
SAMPLES=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift ;;
    --samples) SAMPLES="$2"; shift ;;
    --log) LOG="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
  shift
done

if [[ ! -s "$LOG" ]]; then
  echo "hook-blocks: no blocks logged at $LOG"
  exit 0
fi

since=$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$DAYS"d +%Y-%m-%dT%H:%M:%SZ)

jq -r -R -s --arg since "$since" --argjson n "$SAMPLES" --arg days "$DAYS" '
  split("\n") | map(fromjson? // empty) | map(select((.ts // "") >= $since))
  | "\(length) blocks in the last \($days) days",
    (group_by(.hook) | sort_by(-length) | .[]
     | "", "== \(.[0].hook): \(length) blocks ==",
       (sort_by(.ts) | reverse | .[:$n][]
        | "  \(.ts) [\(.agent)] \(.detail | gsub("\n"; " ") | .[0:160])"))' "$LOG"
