#!/usr/bin/env bash
# Usage: handoff-digest.sh [transcript.jsonl]
# Writes a compact digest of a Claude Code session transcript and prints its path.
# Shell and jq only: no model call happens anywhere in this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAIL_CHARS="${HARNESS_HANDOFF_TAIL_CHARS:-12000}"
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
first_ts="$(grep -m1 -o '"timestamp":"[^"]*"' "$transcript" | head -1 | cut -d'"' -f4 || true)"
root="$(harness_repo_root "$(jq -nc --arg c "$cwd" '{workspace_roots:[$c]}')")"
slug="$(harness_project_slug "$root")"

dest_dir="$OUT_ROOT/$slug"
mkdir -p "$dest_dir"
tmp="$(mktemp "$dest_dir/.$session_id.XXXXXX")"
events="$(mktemp)"
trap 'rm -f "$tmp" "$events"' EXIT

# Repo state is read when the digest is built, so it is the checkout as it stands now,
# which concurrent sessions in the same checkout share.
repo_block=""
if [[ -d "$cwd" ]] && GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_status="$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" status --short 2>/dev/null | head -n 40 || true)"
  git_stat="$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" diff --stat HEAD 2>/dev/null | tail -n 15 || true)"
  git_log=""
  if [[ -n "$first_ts" ]]; then
    git_log="$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" log --oneline --since="$first_ts" -n 15 2>/dev/null || true)"
  fi
  repo_block="cwd: $cwd"
  [[ -n "$git_log" ]] && repo_block+=$'\n\ncommits since the session started:\n'"$git_log"
  [[ -n "$git_status" ]] && repo_block+=$'\n\nstatus:\n'"$git_status"
  [[ -n "$git_stat" ]] && repo_block+=$'\n\ndiff vs HEAD:\n'"$git_stat"
fi

EXTRACT='
def cut($n): if length > $n then .[0:$n] + "..." else . end;
def first_line: split("\n") | map(select(test("\\S"))) | (.[0] // "");
def text_of: if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end;
def clean: gsub("(?s)<system-reminder>.*?</system-reminder>"; "") | gsub("^\\s+|\\s+$"; "");
def pseudo: test("^<(local-command-stdout|local-command-caveat|bash-input|bash-stdout|bash-stderr|ide_opened_file|ide_selection|command-message)");
def command_text:
  ((capture("<command-name>(?<n>[^<]*)</command-name>").n) // "") as $n
  | ((capture("<command-args>(?<a>[^<]*)</command-args>").a) // "") as $a
  | if $a == "" then $n else $n + " " + $a end;
def notification_text:
  ((capture("(?s)<summary>(?<s>.*?)</summary>").s) // "") as $s
  | ((capture("(?s)<result>(?<r>.*?)</result>").r) // "") as $r
  | $s + (if $r == "" then "" else " :: " + ($r | gsub("\\s+"; " ") | cut(600)) end);
def target: (.input | (.command // .file_path // .pattern // .path // .url // .description // tojson)) | tostring | gsub("\n"; " ") | cut(160);

fromjson?
| select(.isSidechain != true and .isMeta != true)
| if .type == "user" then
    .message.content as $c
    | if ($c | type) == "array" and ([$c[] | .type] | index("tool_result")) then
        $c[] | select(.type == "tool_result")
        | {k: "r", tid: .tool_use_id, t: ((.content | if type == "array" then text_of else (. // "" | tostring) end) | cut(700))}
      else
        ($c | text_of | clean) as $t
        | select($t != "")
        | if ($t | test("^\\[Request interrupted")) then {k: "i", t: ($t | cut(160))}
                    elif ($t | test("<command-name>")) then
            ($t | command_text) as $cmd
            | if $cmd == "/clear" then empty else {k: "u", t: ($cmd | cut(8000))} end
          elif ($t | test("^[^<]{0,400}<task-notification>")) then {k: "n", t: ($t | notification_text)}
          elif ($t | pseudo) then empty
          else {k: "u", t: ($t | cut(8000))} end
      end
  elif .type == "assistant" then
    .message.content[]?
    | if .type == "text" then (.text | clean) as $t | select($t != "") | {k: "a", t: ($t | cut(8000))}
      elif .type == "tool_use" then
        {k: "t", id: .id, n: .name, t: (if .name == "ExitPlanMode" then .name else .name + ": " + target end)}
        + (if (.name | IN("Edit", "Write", "NotebookEdit", "MultiEdit")) then {f: (.input.file_path // .input.notebook_path // "")} else {} end)
        + (if .name == "ExitPlanMode" then {p: (.input.plan // "")} else {} end)
      else empty end
  else empty end
'

RENDER='
def cut($n): if length > $n then .[0:$n] + "..." else . end;
def first_line: split("\n") | map(select(test("\\S"))) | (.[0] // "");
def read_only: .k == "t" and (.n | IN("Read", "Grep", "Glob", "LS"));
def size: ((.t // "") | length) + 12;

. as $raw
| ($raw | map(select(.k == "t")) | map({key: (.id // ""), value: .n}) | from_entries) as $names
| ($raw
    | map(
        if .k == "r" then
          ($names[.tid // ""] // "") as $n
          | if ($n | IN("Read", "Grep", "Glob", "LS")) then empty
            elif ($n | IN("Agent", "Task", "SendMessage")) then .t |= (gsub("\\s+"; " ") | cut(600))
            else .t |= (first_line | cut(160)) end
        else . end)
    | reduce .[] as $x ([];
        if ($x | read_only) and length > 0 and (.[-1] | .grp == true)
        then (length - 1) as $i | .[$i].cnt += 1 | .[$i].kinds |= (if index($x.n) then . else . + [$x.n] end)
        elif ($x | read_only) then . + [$x + {grp: true, cnt: 1, kinds: [$x.n]}]
        else . + [$x] end)
    | map(if .grp == true and .cnt > 1 then .t = "reads/searches x\(.cnt) (\(.kinds | join(", ")))" else . end)
  ) as $e
| [range(0; $e | length) | select($e[.].k == "u")] as $p
| ($p | length) as $n
| (if $n == 0 then 0 else
    ([$p | to_entries[]
      | {from: .value, to: ($p[.key + 1] // ($e | length))}
      | .size = ([$e[.from:.to][] | size] | add)]
     | reverse
     | reduce .[] as $t ({sum: 0, start: null, done: false};
         if .done then .
         elif .start == null or (.sum + $t.size <= $budget) then .sum += $t.size | .start = $t.from
         else .done = true end)
     | .start)
  end) as $s
| (if $n == 0 then $e
   else
     $p[-1] as $a
     | ([$e[$a:][] | size] | add) as $asize
     | if $asize > $budget then
         ([$e[$a + 1:] | reverse[]]
          | reduce .[] as $x ({sum: 0, items: [], done: false};
              if .done then .
              elif (.items | length) == 0 or .sum + ($x | size) <= $budget then .sum += ($x | size) | .items += [$x]
              else .done = true end)
          | .items | reverse) as $trail
         | (($e[$a + 1:] | length) - ($trail | length)) as $omitted
         | [$e[$a]]
           + (if $omitted > 0 then [{k: "gap", t: "... \($omitted) earlier events in this turn omitted"}] else [] end)
           + $trail
       else $e[$s:] end
   end) as $tail
| ([$e[] | select(.f != null and .f != "") | .f]
    | reduce .[] as $f ([]; if index($f) then . else . + [$f] end)) as $files
| ([$e[] | select(.p != null and .p != "") | .p] | last // "") as $plan
| "# Handoff digest",
  "session: \($sid)",
  "transcript: \($src)",
  "cwd: \($cwd)",
  "user prompts: \($n)",
  (if ($files | length) > 0 then
     "", "## Files touched (\($files | length))",
     ($files[:40][] | "- " + .),
     (if ($files | length) > 40 then "- ... and \($files | length - 40) more" else empty end)
   else empty end),
  (if $repo != "" then "", "## Repo now (shared by every session in this checkout)", $repo else empty end),
  (if $plan != "" then "", "## Last plan", ($plan | cut(3000) | split("\n") | map("  " + .) | join("\n")) else empty end),
  "",
  "## Last turns (newest turns, up to \($budget) chars)",
  ($tail[] |
    if .k == "u" then "", "### USER", .t
    elif .k == "a" then "", "### ASSISTANT", .t
    elif .k == "t" then "- " + .t
    elif .k == "n" then "  <- agent: " + .t
    elif .k == "i" then "  !! " + .t
    elif .k == "gap" then .t
    else "  -> " + .t end),
  "",
  "## Prompt index",
  ($p | to_entries[] | "\(.key + 1). \($e[.value].t | split("\n")[0] | if length > 120 then .[0:120] + "..." else . end)")
'

grep -E '"type":"(user|assistant)"' "$transcript" \
  | jq -c -R "$EXTRACT" > "$events" || true

jq -rs --argjson budget "$TAIL_CHARS" --arg sid "$session_id" --arg src "$transcript" \
  --arg cwd "$cwd" --arg repo "$repo_block" "$RENDER" "$events" > "$tmp"
mv "$tmp" "$dest_dir/$session_id.md"
printf '%s\n' "$dest_dir/$session_id.md"
