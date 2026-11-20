#!/usr/bin/env bash
# Stops a crew lead from ending its turn with work assigned and nothing
# watching the workers: a lead that goes quiet leaves the crew unattended.
input=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=log-block.sh
source "$HOOK_DIR/log-block.sh"
# shellcheck source=crew-hook-common.sh
source "$HOOK_DIR/crew-hook-common.sh"

[[ $(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null) == true ]] && exit 0
[[ $(crew_hook_role "$input") == lead ]] || exit 0

lib=$(command -v crew-lib.sh) || exit 0
# shellcheck source=/dev/null
. "$lib"
crew=$(crew_dir "$(jq -r '.cwd // "."' <<<"$input")") || exit 0

[[ -f "$crew/board.tsv" ]] || exit 0
awk -F'\t' '$2 == "assigned" { found = 1; exit } END { exit !found }' "$crew/board.tsv" || exit 0
[[ -e "$crew/paused" ]] && exit 0
for f in "$crew"/live/*; do
  crew_live_alive "$f" && exit 0
done

crew_hook_block crew-lead-stop-guard "items are assigned and no crew-sweep is running: start crew-sweep with run_in_background before ending the turn, or write the reason to the crew dir file paused to stop on purpose" "$input"
