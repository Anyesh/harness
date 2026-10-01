#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIGEST="$REPO_ROOT/configs/claude-code/scripts/handoff-digest.sh"
HOOK="$REPO_ROOT/configs/claude-code/hooks/session-start-handoff.sh"
END_HOOK="$REPO_ROOT/configs/claude-code/hooks/session-end-handoff.sh"
COMMON="$REPO_ROOT/configs/claude-code/hooks/handoff-common.sh"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT="$TMP_DIR/My Proj"
PROJ_DIR="$TMP_DIR/projects/enc"
HANDOFFS="$TMP_DIR/handoffs"
mkdir -p "$PROJECT" "$PROJ_DIR"
export HARNESS_HANDOFF_DIR="$HANDOFFS"
export HARNESS_HANDOFF_TAIL_CHARS=450
export HARNESS_HANDOFF_WAIT=0
export CLAUDE_PID=4242

gen_transcript() {
  local out="$1" turns="$2" pad="$3" sid="$4"
  awk -v n="$turns" -v pad="$pad" -v cwd="$PROJECT" -v sid="$sid" 'BEGIN {
    blob = sprintf("%*s", pad, ""); gsub(/ /, "x", blob)
    for (i = 1; i <= n; i++) {
      printf "{\"type\":\"attachment\",\"sessionId\":\"%s\",\"cwd\":\"%s\",\"attachment\":{\"type\":\"skill\",\"content\":\"ATTACHSECRET %s\"}}\n", sid, cwd, blob
      printf "{\"type\":\"user\",\"isSidechain\":false,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"user\",\"content\":\"prompt number %d %s\"}}\n", sid, cwd, i, substr(blob, 1, 300)
      if (i == 2) {
        printf "{\"type\":\"user\",\"isMeta\":true,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"user\",\"content\":\"METASECRET\"}}\n", sid, cwd
        printf "{\"type\":\"user\",\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"<system-reminder>REMSECRET</system-reminder>\"}]}}\n", sid, cwd
      }
      printf "{\"type\":\"assistant\",\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"THINKSECRET\"}]}}\n", sid, cwd
      printf "{\"type\":\"assistant\",\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t%d\",\"name\":\"Bash\",\"input\":{\"command\":\"ls dir%d\",\"description\":\"list\"}}]}}\n", sid, cwd, i, i
      printf "{\"type\":\"user\",\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t%d\",\"content\":\"result line one %d\\nRESULTTAIL %s\"}]}}\n", sid, cwd, i, i, blob
      printf "{\"type\":\"assistant\",\"sessionId\":\"%s\",\"cwd\":\"%s\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"answer number %d\"}]}}\n", sid, cwd, i
    }
  }' > "$out"
}

SMALL="$PROJ_DIR/small-sid.jsonl"
gen_transcript "$SMALL" 10 100 small-sid

echo ""
OUT_PATH=$("$DIGEST" "$SMALL")
DIGEST_FILE="$HANDOFFS/my-proj/small-sid.md"
assert "digest path printed and file lands under <dir>/<slug>/<session-id>.md" \
  '[ "$OUT_PATH" = "$DIGEST_FILE" ] && [ -f "$DIGEST_FILE" ]'
assert "no temp files left beside the digest" \
  '[ "$(ls -A "$HANDOFFS/my-proj" | wc -l)" -eq 1 ]'
assert "index contains every user prompt" \
  '[ "$(grep -c "prompt number" <(sed -n "/^## Prompt index/,\$p" "$DIGEST_FILE"))" -eq 10 ]'
assert "index entries are truncated" \
  '! grep -q "prompt number 1 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" <(sed -n "/^## Prompt index/,\$p" "$DIGEST_FILE")'
TAIL_PART=$(sed -n '/^## Last turns/,/^## Prompt index/p' "$DIGEST_FILE")
assert "tail holds the newest turns that fit the character budget" \
  'grep -q "answer number 10" <<<"$TAIL_PART" && grep -q "answer number 9" <<<"$TAIL_PART" && ! grep -q "answer number 8" <<<"$TAIL_PART"'
assert "tail holds the full last prompt" \
  'grep -q "prompt number 10 x" <<<"$TAIL_PART"'
assert "attachments, thinking, system-reminder, isMeta excluded" \
  '! grep -qE "ATTACHSECRET|THINKSECRET|REMSECRET|METASECRET" "$DIGEST_FILE"'
assert "tool call rendered as a one-liner" \
  'grep -qE "^- Bash: ls dir10$" <<<"$TAIL_PART"'
assert "tool result cut to its first line" \
  'grep -q "result line one 10" <<<"$TAIL_PART" && ! grep -q RESULTTAIL "$DIGEST_FILE"'
assert "recent turns come before the prompt index, which is the last section" \
  '[ "$(grep -n "^## " "$DIGEST_FILE" | tail -n 2 | cut -d: -f2 | sed "s/ (.*//" | tr "\n" "|")" = "## Last turns|## Prompt index|" ]'
HUGE_OUT=$(HARNESS_HANDOFF_TAIL_CHARS=1000000 "$DIGEST" "$SMALL")
assert "a large budget keeps every turn" \
  'grep -q "answer number 1$" "$HUGE_OUT"'
TINY_OUT=$(HARNESS_HANDOFF_TAIL_CHARS=10 "$DIGEST" "$SMALL")
assert "the newest turn is kept even when it exceeds the budget" \
  'grep -q "answer number 10" "$TINY_OUT" && ! grep -q "answer number 9" "$TINY_OUT"'

BIG="$TMP_DIR/projects/enc/big-sid.jsonl"
gen_transcript "$BIG" 850 30000 big-sid
BIG_MB=$(( $(stat -c %s "$BIG") / 1048576 ))
START=$(date +%s.%N)
"$DIGEST" "$BIG" >/dev/null
END=$(date +%s.%N)
ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.2f", e - s }')
printf '  INFO  %s MB fixture digested in %s s\n' "$BIG_MB" "$ELAPSED"
assert "fixture is about 50 MB" '[ "$BIG_MB" -ge 45 ]'
assert "50 MB transcript digests in under 5 s" \
  'awk -v t="$ELAPSED" "BEGIN { exit !(t < 5) }"'
assert "big digest index has every prompt" \
  '[ "$(sed -n "/^## Prompt index/,\$p" "$HANDOFFS/my-proj/big-sid.md" | grep -c "prompt number")" -eq 850 ]'
rm -f "$BIG"

GITREPO="$TMP_DIR/repo"
mkdir -p "$GITREPO"
git -C "$GITREPO" init -q
git -C "$GITREPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "initial work commit"
printf 'a\n' > "$GITREPO/tracked.txt"
git -C "$GITREPO" add tracked.txt
git -C "$GITREPO" -c user.name=t -c user.email=t@t commit -q -m "add tracked file"
printf 'b\n' >> "$GITREPO/tracked.txt"
printf 'n\n' > "$GITREPO/untracked.txt"

AGENT_PAD=$(printf 'p%.0s' $(seq 1 500))
AGENT_FAR=$(printf 'q%.0s' $(seq 1 900))
FEAT="$PROJ_DIR/feat-sid.jsonl"
{
  l() { printf '%s\n' "$1"; }
  c="\"cwd\":\"$GITREPO\",\"sessionId\":\"feat-sid\",\"timestamp\":\"2020-01-01T00:00:00.000Z\""
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"first real prompt\"}}"
  l "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"e1\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/x/a.py\"}},{\"type\":\"tool_use\",\"id\":\"e2\",\"name\":\"Write\",\"input\":{\"file_path\":\"/x/b.py\"}},{\"type\":\"tool_use\",\"id\":\"e3\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/x/a.py\"}},{\"type\":\"tool_use\",\"id\":\"e4\",\"name\":\"NotebookEdit\",\"input\":{\"notebook_path\":\"/x/n.ipynb\"}}]}}"
  l "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"p1\",\"name\":\"ExitPlanMode\",\"input\":{\"plan\":\"OLD PLAN step\"}}]}}"
  l "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"p2\",\"name\":\"ExitPlanMode\",\"input\":{\"plan\":\"FINAL PLAN step\\n## Context\\nwhy\"}}]}}"
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"<command-message>plan</command-message>\\n<command-name>/plan</command-name>\\n<command-args>do the thing</command-args>\"}}"
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"<local-command-stdout>STDOUTNOISE</local-command-stdout>\"}}"
  l "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"ag1\",\"name\":\"Agent\",\"input\":{\"description\":\"review\"}}]}}"
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"ag1\",\"content\":\"AGENTSTART $AGENT_PAD AGENTMID $AGENT_FAR AGENTFAR\"}]}}"
  for i in 1 2 3 4 5; do
    l "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"r$i\",\"name\":\"Read\",\"input\":{\"file_path\":\"/x/read$i.txt\"}}]}}"
    l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"r$i\",\"content\":\"READBODY$i\"}]}}"
  done
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"<task-notification><task-id>zz</task-id><summary>Agent finished review</summary><result>NOTIFRESULT body\\nSECONDLINE tail</result></task-notification>\"}}"
  l "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"final words\"}]}}"
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"[SYSTEM NOTIFICATION] preamble text <task-notification><summary>Preamble agent done</summary><result>PREAMBLERES</result></task-notification>\"}}"
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"<command-name>/clear</command-name>\\n<command-args></command-args>\"}}"
  l "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"[Request interrupted by user for tool use]\"}]}}"
} > "$FEAT"
FEAT_FILE=$(HARNESS_HANDOFF_TAIL_CHARS=100000 "$DIGEST" "$FEAT")
FILES_PART=$(sed -n '/^## Files touched/,/^## Repo/p' "$FEAT_FILE")
assert "files touched lists each edited file once, in first-touch order" \
  '[ "$(grep -c "^- /x/" <<<"$FILES_PART")" -eq 3 ] && [ "$(grep "^- /x/" <<<"$FILES_PART" | head -n 1)" = "- /x/a.py" ] && grep -q "/x/n.ipynb" <<<"$FILES_PART"'
REPO_PART=$(sed -n '/^## Repo now/,/^## Last plan/p' "$FEAT_FILE")
assert "repo section carries git status for the session cwd" \
  'grep -q "untracked.txt" <<<"$REPO_PART" && grep -q "tracked.txt" <<<"$REPO_PART"'
assert "repo section lists commits made since the session started" \
  'grep -q "add tracked file" <<<"$REPO_PART"'
assert "last plan keeps only the final ExitPlanMode plan" \
  'sed -n "/^## Last plan/,/^## Last turns/p" "$FEAT_FILE" | grep -q "FINAL PLAN" && ! grep -q "OLD PLAN" "$FEAT_FILE"'
INDEX_PART=$(sed -n '/^## Prompt index/,$p' "$FEAT_FILE")
assert "prompt index keeps the real prompt and renders the slash command" \
  'grep -q "first real prompt" <<<"$INDEX_PART" && grep -q "/plan do the thing" <<<"$INDEX_PART"'
assert "pseudo prompts stay out of the index" \
  '! grep -qE "STDOUTNOISE|task-notification|command-name|NOTIFRESULT" <<<"$INDEX_PART"'
FEAT_TAIL=$(sed -n '/^## Last turns/,/^## Prompt index/p' "$FEAT_FILE")
assert "local command output is dropped from the tail" \
  '! grep -q STDOUTNOISE <<<"$FEAT_TAIL"'
assert "agent notifications appear in the tail as results" \
  'grep -q "Agent finished review" <<<"$FEAT_TAIL" && grep -q "NOTIFRESULT" <<<"$FEAT_TAIL" && grep -q "SECONDLINE" <<<"$FEAT_TAIL"'
assert "subagent result keeps about 600 chars, not one line" \
  'grep -q AGENTMID <<<"$FEAT_TAIL" && ! grep -q AGENTFAR <<<"$FEAT_TAIL"'
assert "interrupt marker is not a prompt: index and prompt count skip it, tail keeps earlier content" \
  '! grep -q "Request interrupted" <<<"$INDEX_PART" && grep -q "^user prompts: 2$" "$FEAT_FILE" && grep -q "final words" <<<"$FEAT_TAIL" && grep -q "interrupted" <<<"$FEAT_TAIL"'
assert "a notification with a preamble is still a notification, and /clear is not a prompt" \
  'grep -q PREAMBLERES <<<"$FEAT_TAIL" && ! grep -q "PREAMBLERES\|/clear" <<<"$INDEX_PART" && ! grep -q "^/clear" <<<"$FEAT_TAIL"'
assert "plan headings are indented so they do not mix with digest sections" \
  '! grep -q "^## Context" "$FEAT_FILE"'
assert "run of Read calls collapses into one counted line" \
  'grep -q "reads/searches x5" <<<"$FEAT_TAIL" && ! grep -q "^- Read:" <<<"$FEAT_TAIL" && ! grep -q READBODY <<<"$FEAT_TAIL"'

BIGTURN="$PROJ_DIR/bigturn-sid.jsonl"
{
  c="\"cwd\":\"$PROJECT\",\"sessionId\":\"bigturn-sid\""
  printf '%s\n' "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"older prompt\"}}"
  printf '%s\n' "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":\"the long autonomous task\"}}"
  for i in $(seq 1 40); do
    printf '%s\n' "{\"type\":\"assistant\",$c,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"b$i\",\"name\":\"Bash\",\"input\":{\"command\":\"echo step$i\"}}]}}"
    printf '%s\n' "{\"type\":\"user\",$c,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"b$i\",\"content\":\"ok$i\"}]}}"
  done
} > "$BIGTURN"
BIG_FILE=$("$DIGEST" "$BIGTURN")
BIG_TAIL=$(sed -n '/^## Last turns/,/^## Prompt index/p' "$BIG_FILE")
assert "an oversized newest turn keeps its prompt and its trailing events" \
  'grep -q "the long autonomous task" <<<"$BIG_TAIL" && grep -q "echo step40" <<<"$BIG_TAIL" && ! grep -q "echo step1$" <<<"$BIG_TAIL" && grep -q "earlier events in this turn omitted" <<<"$BIG_TAIL"'
assert "an oversized newest turn stays within about twice the budget" \
  '[ "$(printf "%s" "$BIG_TAIL" | wc -c)" -lt 1200 ]'
command rm -f "$BIGTURN"

NOGIT="$TMP_DIR/nogit"
mkdir -p "$NOGIT"
sed "s#$GITREPO#$NOGIT#g" "$FEAT" > "$PROJ_DIR/nogit-sid.jsonl"
NOGIT_FILE=$("$DIGEST" "$PROJ_DIR/nogit-sid.jsonl")
assert "no repo section when the session cwd is not a git repository" \
  '! grep -q "^## Repo now" "$NOGIT_FILE"'
rm -f "$FEAT" "$PROJ_DIR/nogit-sid.jsonl"

PEND="$HANDOFFS/.pending"
OLD="$PROJ_DIR/old-sid.jsonl"
NEW="$PROJ_DIR/new-sid.jsonl"
gen_transcript "$OLD" 4 50 old-sid
touch "$NEW"
rm -rf "$HANDOFFS"

run_start() { bash "$HOOK" <<<"$1"; }
run_end() { bash "$END_HOOK" <<<"$1"; }
end_payload() {
  printf '{"hook_event_name":"SessionEnd","reason":"%s","session_id":"old-sid","transcript_path":"%s","cwd":"%s"}' "$1" "$OLD" "$PROJECT"
}
start_payload() {
  printf '{"hook_event_name":"SessionStart","source":"%s","session_id":"new-sid","transcript_path":"%s","cwd":"%s"}' "$1" "$NEW" "$PROJECT"
}

run_end "$(end_payload prompt_input_exit)"
assert "session end for another reason leaves no pointer" '[ ! -e "$PEND/4242.json" ]'
run_end "$(end_payload clear)"
assert "session end on clear writes a pointer keyed by the claude pid" \
  'jq -e --arg t "$OLD" --arg c "$PROJECT" ".transcript_path == \$t and .cwd == \$c and .session_id == \"old-sid\" and (.ts | type) == \"number\"" "$PEND/4242.json" >/dev/null'
assert "no temp files left beside the pointer" '[ "$(ls -A "$PEND" | wc -l)" -eq 1 ]'

for src in startup resume compact; do
  OUT=$(run_start "$(start_payload $src)"; echo "rc=$?")
  assert "source $src emits nothing and leaves the pointer alone" '[ "$OUT" = "rc=0" ] && [ -e "$PEND/4242.json" ]'
done

OUT=$(run_start "$(start_payload clear)")
assert "clear emits valid hook JSON" 'jq -e .hookSpecificOutput.additionalContext <<<"$OUT" >/dev/null'
CTX=$(jq -r .hookSpecificOutput.additionalContext <<<"$OUT")
OLD_DIGEST="$HANDOFFS/my-proj/old-sid.md"
assert "context names the digest of the exact previous transcript" 'grep -qF "$OLD_DIGEST" <<<"$CTX" && [ -f "$OLD_DIGEST" ]'
IDX=$(grep -n "^## Prompt index" "$OLD_DIGEST" | cut -d: -f1)
assert "context tells the reader which lines to read first" \
  'grep -qF "lines 1-$((IDX - 1))" <<<"$CTX"'
assert "pointer is consumed after use" '[ ! -e "$PEND/4242.json" ]'

OUT=$(run_start "$(start_payload clear)"; echo "rc=$?")
assert "second clear without a new pointer emits nothing" '[ "$OUT" = "rc=0" ]'

touch "$OLD"
OUT=$(run_start "$(start_payload clear)"; echo "rc=$?")
assert "no pointer means no handoff, even with a fresher transcript on disk" '[ "$OUT" = "rc=0" ]'

run_end "$(end_payload clear)"
jq '.ts -= 100' "$PEND/4242.json" > "$PEND/4242.tmp" && command mv "$PEND/4242.tmp" "$PEND/4242.json"
OUT=$(run_start "$(start_payload clear)"; echo "rc=$?")
assert "stale pointer is ignored" '[ "$OUT" = "rc=0" ]'

command rm -f "$PEND"/*.json
( sleep 0.4; run_end "$(end_payload clear)" ) &
OUT=$(HARNESS_HANDOFF_WAIT=3 run_start "$(start_payload clear)")
wait
assert "start waits for a pointer that is written a moment later" \
  'jq -r .hookSpecificOutput.additionalContext <<<"$OUT" | grep -qF "$OLD_DIGEST"'

run_end "$(end_payload clear)"
OUT=$(CLAUDE_PID=9999 run_start "$(start_payload clear)"; echo "rc=$?")
assert "a pointer for another claude process is not picked up" '[ "$OUT" = "rc=0" ] && [ -e "$PEND/4242.json" ]'

printf '{}' > "$PEND/9999.json"
touch -d '3 days ago' "$PEND/9999.json"
mkdir -p "$HANDOFFS/my-proj"
touch -d '20 days ago' "$HANDOFFS/my-proj/ancient.md"
touch "$HANDOFFS/my-proj/recent.md"
run_start "$(start_payload clear)" >/dev/null
assert "old digests are pruned and recent ones kept" \
  '[ ! -e "$HANDOFFS/my-proj/ancient.md" ] && [ -e "$HANDOFFS/my-proj/recent.md" ]'
assert "stale pointers of dead processes are pruned" '[ ! -e "$PEND/9999.json" ]'

FAKEBIN="$TMP_DIR/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ps" <<'FAKEPS'
#!/usr/bin/env bash
want="" pid=""
while [ $# -gt 0 ]; do
  case "$1" in -o) want="$2"; shift 2 ;; -p) pid="$2"; shift 2 ;; *) shift ;; esac
done
case "$pid:$want" in
  100:ppid=) echo 200 ;; 100:comm=) echo bash ;;
  200:ppid=) echo 300 ;; 200:comm=) echo zsh ;;
  300:ppid=) echo 1 ;;   300:comm=) echo claude ;;
  *) exit 1 ;;
esac
FAKEPS
chmod +x "$FAKEBIN/ps"
WALK=$(env -u CLAUDE_PID PATH="$FAKEBIN:$PATH" bash -c "source '$COMMON'; handoff_claude_pid 100")
assert "without CLAUDE_PID the ancestor walk finds the claude process" '[ "$WALK" = "300" ]'
assert "CLAUDE_PID wins over the ancestor walk" \
  '[ "$(CLAUDE_PID=777 PATH="$FAKEBIN:$PATH" bash -c "source \"$COMMON\"; handoff_claude_pid 100")" = "777" ]'

echo ""
echo "handoff-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
