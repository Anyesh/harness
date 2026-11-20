#!/usr/bin/env bash
# Keeps crew panes off blocking dialogs: herdr cannot deliver a prompt to a pane
# that sits in a question or plan dialog, which stalls the whole crew.
input=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
# shellcheck source=crew-hook-common.sh
source "$HOOK_DIR/crew-hook-common.sh"
harness_log_block_on_exit crew-question-guard "$input"

deny() {
  jq -cn --arg m "BLOCKED by crew-question-guard: $1" '{decision: "deny", reason: $m}' >&2
  exit 2
}

role=$(crew_hook_role "$input") || exit 0

case "$role" in
  worker) deny "write the question to report.md with status question and stop" ;;
  lead) deny "a crew is running: write the plan into rulings.md and ask in plain text at the end of the turn (if you are in plan mode, ask the user to press Shift+Tab)" ;;
esac
exit 0
