#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIGEST="$REPO_ROOT/configs/claude-code/scripts/handoff-digest.sh"
HOOK="$REPO_ROOT/configs/claude-code/hooks/session-start-handoff.sh"

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
export HARNESS_HANDOFF_TURNS=3

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
  '[ "$(grep -c "prompt number" <(sed -n "/^## Prompt index/,/^## Last/p" "$DIGEST_FILE"))" -eq 10 ]'
assert "index entries are truncated" \
  '! grep -q "prompt number 1 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" <(sed -n "/^## Prompt index/,/^## Last/p" "$DIGEST_FILE")'
TAIL_PART=$(sed -n '/^## Last/,$p' "$DIGEST_FILE")
assert "tail holds only the last 3 turns" \
  'grep -q "answer number 10" <<<"$TAIL_PART" && grep -q "answer number 8" <<<"$TAIL_PART" && ! grep -q "answer number 7" <<<"$TAIL_PART"'
assert "tail holds the full last prompt" \
  'grep -q "prompt number 10 x" <<<"$TAIL_PART"'
assert "attachments, thinking, system-reminder, isMeta excluded" \
  '! grep -qE "ATTACHSECRET|THINKSECRET|REMSECRET|METASECRET" "$DIGEST_FILE"'
assert "tool call rendered as a one-liner" \
  'grep -qE "^- Bash: ls dir10$" <<<"$TAIL_PART"'
assert "tool result cut to its first line" \
  'grep -q "result line one 10" <<<"$TAIL_PART" && ! grep -q RESULTTAIL "$DIGEST_FILE"'
assert "digest ends with the tail so the last lines are the newest turns" \
  'tail -n 3 "$DIGEST_FILE" | grep -q "answer number 10"'

BIG="$TMP_DIR/projects/enc/big-sid.jsonl"
gen_transcript "$BIG" 850 30000 big-sid
BIG_MB=$(( $(stat -c %s "$BIG") / 1048576 ))
START=$(date +%s.%N)
"$DIGEST" "$BIG" >/dev/null
END=$(date +%s.%N)
ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.2f", e - s }')
printf '  INFO  %s MB fixture digested in %s s\n' "$BIG_MB" "$ELAPSED"
assert "fixture is about 50 MB" '[ "$BIG_MB" -ge 45 ]'
assert "50 MB transcript digests in under 2 s" \
  'awk -v t="$ELAPSED" "BEGIN { exit !(t < 2) }"'
assert "big digest index has every prompt" \
  '[ "$(sed -n "/^## Prompt index/,/^## Last/p" "$HANDOFFS/my-proj/big-sid.md" | grep -c "prompt number")" -eq 850 ]'
rm -f "$BIG"

run_hook() {
  HARNESS_HANDOFF_DIR="$HANDOFFS" bash "$HOOK" <<<"$1"
}

NEW="$PROJ_DIR/new-sid.jsonl"
touch "$NEW"
rm -rf "$HANDOFFS"
touch -d '1 minute ago' "$SMALL"

for src in startup resume compact; do
  OUT=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"$src\",\"transcript_path\":\"$NEW\"}"; echo "rc=$?")
  assert "source $src emits nothing and exits 0" '[ "$OUT" = "rc=0" ]'
done
assert "source clear without transcript_path exits 0 silently" \
  '[ "$(run_hook "{\"source\":\"clear\"}"; echo "rc=$?")" = "rc=0" ]'

OUT=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"clear\",\"transcript_path\":\"$NEW\"}")
assert "clear with mtime fallback emits valid JSON" \
  'jq -e .hookSpecificOutput.additionalContext <<<"$OUT" >/dev/null'
CTX=$(jq -r .hookSpecificOutput.additionalContext <<<"$OUT")
assert "context names digest path" 'grep -qF "$DIGEST_FILE" <<<"$CTX"'
LINES=$(wc -l < "$DIGEST_FILE")
assert "context states line count" 'grep -qE "(^|[^0-9])$LINES lines" <<<"$CTX"'
assert "context carries the read-last-80-lines instruction" \
  'grep -q "last ~80 lines" <<<"$CTX" && grep -q "only if needed" <<<"$CTX"'

rm -rf "$HANDOFFS"
OTHER="$PROJ_DIR/other-sid.jsonl"
gen_transcript "$OTHER" 4 50 other-sid
touch -d '1 hour ago' "$OTHER"
OUT=$(run_hook "{\"source\":\"clear\",\"transcript_path\":\"$NEW\",\"previous_session_id\":\"other-sid\"}")
assert "payload previous_session_id wins over newest mtime" \
  'jq -r .hookSpecificOutput.additionalContext <<<"$OUT" | grep -qF "$HANDOFFS/my-proj/other-sid.md"'
rm -rf "$HANDOFFS"
OUT=$(run_hook "{\"source\":\"clear\",\"transcript_path\":\"$NEW\",\"previous_transcript_path\":\"$OTHER\"}")
assert "payload previous_transcript_path is honored" \
  'jq -r .hookSpecificOutput.additionalContext <<<"$OUT" | grep -qF "$HANDOFFS/my-proj/other-sid.md"'

rm -rf "$HANDOFFS"
touch -d '3 days ago' "$SMALL" "$OTHER"
OUT=$(run_hook "{\"source\":\"clear\",\"transcript_path\":\"$NEW\"}"; echo "rc=$?")
assert "stale candidates fail the freshness check, silent exit 0" '[ "$OUT" = "rc=0" ]'

rm -f "$SMALL" "$OTHER"
OUT=$(run_hook "{\"source\":\"clear\",\"transcript_path\":\"$NEW\"}"; echo "rc=$?")
assert "no previous transcript exits 0 silently" '[ "$OUT" = "rc=0" ]'
assert "no digest written when nothing to digest" '[ ! -d "$HANDOFFS/my-proj" ]'

echo ""
echo "handoff-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
