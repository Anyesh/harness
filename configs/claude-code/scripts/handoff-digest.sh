#!/usr/bin/env bash
# Usage: handoff-digest.sh [transcript.jsonl]
# Writes a compact digest of a Claude Code session transcript and prints its path.
# Shell and jq only: no model call happens anywhere in this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TURNS="${HARNESS_HANDOFF_TURNS:-6}"
OUT_ROOT="${HARNESS_HANDOFF_DIR:-$HOME/.claude/handoffs}"

for candidate in "$SCRIPT_DIR/../hooks" "$SCRIPT_DIR/../../shared/hooks"; do
  if [[ -f "$candidate/harness-project.sh" ]]; then
    # shellcheck source=/dev/null
    source "$candidate/harness-project.sh"
    break
  fi
done
declare -F harness_project_slug >/dev/null || { echo "handoff-digest: harness-project.sh not found" >&2; exit 1; }

transcript="${1:-}"
if [[ -z "$transcript" ]]; then
  encoded="$(pwd | sed 's/[^A-Za-z0-9]/-/g')"
  transcript="$(ls -t "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$encoded"/*.jsonl 2>/dev/null | head -1 || true)"
fi
[[ -n "$transcript" && -f "$transcript" ]] || { echo "handoff-digest: no transcript found" >&2; exit 1; }

session_id="$(basename "$transcript" .jsonl)"
cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$transcript" | head -1 | sed 's/^"cwd":"//;s/"$//' || true)"
[[ -n "$cwd" ]] || cwd="$PWD"
root="$(harness_repo_root "$(jq -nc --arg c "$cwd" '{workspace_roots:[$c]}')")"
slug="$(harness_project_slug "$root")"

dest_dir="$OUT_ROOT/$slug"
mkdir -p "$dest_dir"
tmp="$(mktemp "$dest_dir/.$session_id.XXXXXX")"
events="$(mktemp)"
trap 'rm -f "$tmp" "$events"' EXIT

EXTRACT='
def cut($n): if length > $n then .[0:$n] + "..." else . end;
def first_line: split("\n") | map(select(test("\\S"))) | (.[0] // "");
def text_of: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end;
def clean: gsub("(?s)<system-reminder>.*?</system-reminder>"; "") | gsub("^\\s+|\\s+$"; "");
select(.isSidechain != true and .isMeta != true)
| if .type == "user" then
    .message.content as $c
    | if ($c | type) == "array" and ([$c[] | .type] | index("tool_result")) then
        $c[] | select(.type == "tool_result")
        | {k: "r", t: ((.content | if type == "array" then text_of else (. // "" | tostring) end) | first_line | cut(160))}
      else
        ($c | text_of | clean) as $t | select($t != "") | {k: "u", t: ($t | cut(8000))}
      end
  elif .type == "assistant" then
    .message.content[]?
    | if .type == "text" then (.text | clean) as $t | select($t != "") | {k: "a", t: ($t | cut(8000))}
      elif .type == "tool_use" then
        {k: "t", t: (.name + ": " + ((.input | (.command // .file_path // .pattern // .path // .url // .description // tojson)) | tostring | gsub("\n"; " ") | cut(160)))}
      else empty end
  else empty end
'

RENDER='
. as $e
| [range(0; length) | select($e[.].k == "u")] as $p
| ($p | length) as $n
| (if $n > $turns then $p[$n - $turns] else 0 end) as $s
| "# Handoff digest",
  "session: \($sid)",
  "transcript: \($src)",
  "user prompts: \($n)",
  "",
  "## Prompt index",
  ($p | to_entries[] | "\(.key + 1). \($e[.value].t | split("\n")[0] | if length > 120 then .[0:120] + "..." else . end)"),
  "",
  "## Last \([$n, $turns] | min) turns (full)",
  ($e[$s:][] |
    if .k == "u" then "", "### USER", .t
    elif .k == "a" then "", "### ASSISTANT", .t
    elif .k == "t" then "- " + .t
    else "  -> " + .t end)
'

grep -E '"type":"(user|assistant)"' "$transcript" \
  | jq -c "$EXTRACT" > "$events" || true

jq -rs --argjson turns "$TURNS" --arg sid "$session_id" --arg src "$transcript" "$RENDER" "$events" > "$tmp"
mv "$tmp" "$dest_dir/$session_id.md"
printf '%s\n' "$dest_dir/$session_id.md"
