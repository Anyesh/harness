#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: guard-replay.sh [--transcripts N] [--samples N] [--hook NAME] [--jobs N]

Replays tool calls from the N most recent Claude Code transcripts (default 60,
subagents included) through this repo's current PreToolUse guards, as listed
in configs/claude-code/settings.json.tmpl, and reports per guard how many
distinct calls it checked and blocked, with sample blocked calls.

Run it before shipping a guard change and read every sample: a block on a
command an agent legitimately runs is a false positive.
EOF
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TRANSCRIPTS=60
SAMPLES=8
ONLY_HOOK=""
JOBS=$(nproc 2>/dev/null || echo 4)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcripts) TRANSCRIPTS="$2"; shift ;;
    --samples) SAMPLES="$2"; shift ;;
    --hook) ONLY_HOOK="$2"; shift ;;
    --jobs) JOBS="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
  shift
done

WORK=$(mktemp -d)
trap 'command rm -rf "$WORK"' EXIT

# Claude deploys shared and claude-code hooks into one directory, and guards
# find log-block.sh and detect-agent.sh next to themselves.
mkdir -p "$WORK/hooks" "$WORK/calls"
command cp "$REPO_ROOT"/configs/shared/hooks/* "$REPO_ROOT"/configs/claude-code/hooks/* "$WORK/hooks/"

mapfile -t transcripts < <(
  find "$CONFIG_DIR/projects" -name '*.jsonl' -type f -exec stat -c '%Y %n' {} + 2>/dev/null |
    sort -rn | head -n "$TRANSCRIPTS" | cut -d' ' -f2-
)
if [[ ${#transcripts[@]} -eq 0 ]]; then
  echo "guard-replay: no transcripts under $CONFIG_DIR/projects" >&2
  exit 1
fi

# Retries and repeated commands would inflate the counts, so each distinct
# tool call is replayed once.
for t in "${transcripts[@]}"; do
  jq -c -R 'fromjson? | select(.type == "assistant") | .cwd as $cwd | .sessionId as $s
    | .message.content[]? | select(.type == "tool_use")
    | {k: {tool_name: .name, tool_input: .input},
       p: {hook_event_name: "PreToolUse", tool_name: .name, tool_input: .input,
           cwd: ($cwd // ""), session_id: ($s // "")}}' "$t"
done | jq -c -s 'unique_by(.k) | .[].p' >"$WORK/calls.jsonl"

jq -r '.tool_name' "$WORK/calls.jsonl" >"$WORK/names.txt"
awk -v d="$WORK/calls" '{ f = sprintf("%s/%06d.json", d, NR); print > f; close(f) }' "$WORK/calls.jsonl"

cat >"$WORK/run-one.sh" <<'EOF'
#!/usr/bin/env bash
runner=$1 hook=$2 name=$3 call=$4
cwd=$(jq -r '.cwd // empty' "$call")
[[ -d "$cwd" ]] || cwd=/
limit=()
command -v timeout >/dev/null && limit=(timeout 10)
out=$(cd "$cwd" && HARNESS_BLOCK_LOG=/dev/null "${limit[@]}" "$runner" "$hook" <"$call" 2>"$call.$name.err")
rc=$?
msg=""
if [[ $rc -eq 2 ]]; then
  msg=$(grep -m1 -v '^[[:space:]]*$' "$call.$name.err")
elif [[ -n "$out" ]]; then
  msg=$(printf '%s' "$out" | jq -r 'select((.decision // .permission // .hookSpecificOutput.permissionDecision // "")
    | IN("block", "deny")) | .reason // .user_message // .hookSpecificOutput.permissionDecisionReason // "denied"' 2>/dev/null | head -n 1)
fi
if [[ -n "$msg" ]]; then
  printf '%s\n' "$msg" >"$call.$name.msg"
  printf 'B\t%s\n' "$call"
else
  printf 'A\t%s\n' "$call"
fi
EOF

guards=()
while IFS=$'\t' read -r matcher command; do
  read -r runner script <<<"$command"
  file=$(basename "$script")
  name="${file%.*}"
  [[ -n "$ONLY_HOOK" && "$name" != "$ONLY_HOOK" ]] && continue
  guards+=("$name")
  grep -nxE "($matcher)" "$WORK/names.txt" | cut -d: -f1 |
    awk -v d="$WORK/calls" '{ printf "%s/%06d.json\n", d, $1 }' |
    xargs -r -P "$JOBS" -I{} bash "$WORK/run-one.sh" "$runner" "$WORK/hooks/$file" "$name" {} >"$WORK/$name.results"
done < <(jq -r '.hooks.PreToolUse[] | .matcher as $m | .hooks[] | [$m, .command] | @tsv' \
  "$REPO_ROOT/configs/claude-code/settings.json.tmpl")

echo "Replayed ${#transcripts[@]} transcripts, $(wc -l <"$WORK/calls.jsonl") distinct tool calls"
echo ""
printf '%-28s %8s %8s\n' guard checked blocked
for name in "${guards[@]}"; do
  printf '%-28s %8d %8d\n' "$name" "$(wc -l <"$WORK/$name.results")" "$(grep -c '^B' "$WORK/$name.results" || true)"
done

for name in "${guards[@]}"; do
  blocked=$(grep -c '^B' "$WORK/$name.results" || true)
  [[ "$blocked" -gt 0 ]] || continue
  echo ""
  echo "== $name: $blocked blocked (showing up to $SAMPLES) =="
  grep '^B' "$WORK/$name.results" | cut -f2 | sort | head -n "$SAMPLES" | while read -r call; do
    detail=$(jq -r '.tool_input.command // .tool_input.file_path // .tool_input.path // .tool_input.notebook_path // (.tool_input | tostring)' "$call" |
      tr '\n' ' ' | cut -c1-200)
    printf '  %s\n    %s\n' "$detail" "$(cut -c1-200 "$call.$name.msg")"
  done
done
