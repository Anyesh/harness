#!/usr/bin/env bash
set -euo pipefail

INSTALL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$INSTALL/state"
DENO="$INSTALL/deno/deno"
# shellcheck source=/dev/null
source "$INSTALL/env"
export DENO_DIR="$STATE/deno" WIKI_SYNC_STATE="$STATE" WIKI_SYNC_VAULT WIKI_SYNC_DIR DENO_NO_UPDATE_CHECK=1
DATA_JSON="$WIKI_SYNC_VAULT/.obsidian/plugins/obsidian-livesync/data.json"
mkdir -p "$STATE"

if [[ "${1:-}" == --release-deletions ]]; then
  : >"$STATE/release-deletions"
  echo "wiki-sync will push the deletions it is holding within a few seconds"
  exit 0
fi

OBSIDIAN_JSON=(
  "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/obsidian.json"
  "$HOME/.var/app/md.obsidian.Obsidian/config/obsidian/obsidian.json"
  "$HOME/Library/Application Support/obsidian/obsidian.json"
)

file_id() {
  stat -L -c '%d:%i' "$1" 2>/dev/null || stat -L -f '%d:%i' "$1" 2>/dev/null
}

vault_keys() {
  local want f key path
  want=$(file_id "$WIKI_SYNC_VAULT") || return 0
  for f in "${OBSIDIAN_JSON[@]}"; do
    [[ -r "$f" ]] || continue
    while IFS=$'\t' read -r key path; do
      [[ -n "$path" && "$(file_id "$path")" == "$want" ]] && printf '%s\n' "$key"
    done < <(jq -r '.vaults // {} | to_entries[] | "\(.key)\t\(.value.path // "")"' "$f" 2>/dev/null || true)
  done
}

READ="$WIKI_SYNC_DIR,$INSTALL,$DATA_JSON,$(IFS=,; echo "${OBSIDIAN_JSON[*]}")"
ENVS=WIKI_SYNC_STATE,WIKI_SYNC_VAULT,WIKI_SYNC_DIR,WIKI_SYNC_OBSIDIAN_JSON,WIKI_SYNC_OBSIDIAN_KEYS,DENO_DIR
deno_run() {
  "$DENO" run --cached-only --frozen --no-prompt --ignore-env --allow-env="$ENVS" --allow-read="$READ" "$@"
}

if [[ "${1:-}" == --check-fingerprint ]]; then
  deno_run --allow-write="$STATE" "$INSTALL/src/main.ts" --check-fingerprint
  exit $?
fi

fp=$(deno_run --allow-write="$STATE" "$INSTALL/src/main.ts" --fingerprint)
host=$(jq -r .host <<<"$fp")
[[ -n "$host" && "$host" != null ]] || {
  echo "wiki-sync: could not read the CouchDB host from the plugin settings" >&2
  exit 1
}
printf '%s\n' "$fp" >"$STATE/settings-seen.tmp"
mv -f "$STATE/settings-seen.tmp" "$STATE/settings-seen"

WIKI_SYNC_OBSIDIAN_JSON=$(printf '%s\n' "${OBSIDIAN_JSON[@]}")
WIKI_SYNC_OBSIDIAN_KEYS=$(vault_keys)
export WIKI_SYNC_OBSIDIAN_JSON WIKI_SYNC_OBSIDIAN_KEYS

exec "$DENO" run --cached-only --frozen --no-prompt --ignore-env --allow-env="$ENVS" --allow-read="$READ" \
  --allow-write="$WIKI_SYNC_DIR,$INSTALL" --allow-net="$host" --allow-run=ps "$INSTALL/src/main.ts"
