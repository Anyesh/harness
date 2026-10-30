#!/usr/bin/env bash
set -euo pipefail

unset HARNESS_UNATTENDED HARNESS_NOTIFY HERDR_PANE_ID
while read -r name; do
  [[ "$name" == GIT_CONFIG_* ]] && unset "$name"
done < <(compgen -e)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARNESS_BLOCK_LOG=/dev/null
HOOK="$REPO_ROOT/configs/shared/hooks/stop-wiki-enforce.sh"

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

STATE_DIR="$TMP_DIR/state"
PROJECT="$TMP_DIR/myproj"
VAULT="$TMP_DIR/vault"
mkdir -p "$STATE_DIR" "$PROJECT" "$VAULT/wiki/projects/myproj"
export HARNESS_ENV="$TMP_DIR/harness.env" XDG_STATE_HOME="$TMP_DIR/xdg"
: >"$HARNESS_ENV"
PINDEX="$VAULT/wiki/projects/myproj/index.md"
DEVLOG="$VAULT/wiki/projects/myproj/devlog.md"

payload() {
  jq -n --arg id "$1" --arg t "${2:-}" \
    '{session_id: $id, hook_event_name: "Stop", transcript_path: $t}'
}

run_hook() {
  WIKI_ENFORCE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" \
    CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<"$1"
}

tool_use() {
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"file_path":"%s"}}]}}\n' "$1" "$2"
}

bash_use() {
  jq -cn --arg name "$1" --arg cmd "$2" \
    '{type:"assistant",message:{content:[{type:"tool_use",name:$name,input:{command:$cmd}}]}}'
}

echo ""

# A conversation-only session: tool names appear in transcript text but no
# file mutations happened. Must stay silent.
T_IDLE="$TMP_DIR/idle.jsonl"
{
  printf '{"type":"user","message":{"content":"hi"}}\n'
  tool_use "ToolSearch" "/tmp/x"
} > "$T_IDLE"
OUT=$(run_hook "$(payload "s-idle" "$T_IDLE")")
assert "zero-edit session stays silent" '[ -z "$OUT" ]'

# The prompt_snapshot attachment Claude Code logs once per session embeds the
# full tool schema list, so every available tool's name appears as bare
# "name":"X" text even though none were ever invoked. A text-based count must
# not mistake schema definitions for tool_use calls.
T_SCHEMA="$TMP_DIR/schema.jsonl"
{
  jq -cn '{type:"attachment",attachment:{tools:[
    {name:"Write",description:"writes a file"},
    {name:"Write",description:"writes a file"},
    {name:"Edit",description:"edits a file"},
    {name:"Edit",description:"edits a file"}
  ]}}'
  printf '{"type":"user","message":{"content":"hi"}}\n'
} > "$T_SCHEMA"
OUT=$(run_hook "$(payload "s-schema" "$T_SCHEMA")")
assert "tool schema names in a prompt snapshot are not counted as edits" '[ -z "$OUT" ]'

T_EDITS="$TMP_DIR/edits.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "/tmp/c"
} > "$T_EDITS"
OUT=$(run_hook "$(payload "s-edits" "$T_EDITS")")
assert "3 native edits without wiki writes fires" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'

OUT=$(run_hook "$(payload "s-edits" "$T_EDITS")")
assert "already-fired session stays silent" '[ -z "$OUT" ]'

OUT=$(HARNESS_UNATTENDED=1 run_hook "$(payload "s-unattended" "$T_EDITS")")
assert "unattended session with 3 edits stays silent" '[ -z "$OUT" ]'

OUT=$(HARNESS_UNATTENDED=0 run_hook "$(payload "s-attended" "$T_EDITS")")
assert "HARNESS_UNATTENDED other than 1 still fires" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'

# Claude Code logs an api-request-blob line that repeats each assistant
# message's tool_use blocks under the same ids.
id_use() {
  jq -cn --arg id "$1" --arg p "$2" \
    '{type:"assistant",message:{content:[{type:"tool_use",id:$id,name:"Write",input:{file_path:$p}}]}}'
}
replay() {
  jq -cn '{type:"api-request-blob",message:{role:"assistant",content:[$ARGS.positional[]
    | {type:"tool_use",id:.,name:"Write",input:{file_path:"/tmp/x"}}]}}' --args "$@"
}

T_REPLAY2="$TMP_DIR/replay2.jsonl"
{
  id_use toolu_a /tmp/a
  id_use toolu_b /tmp/b
  replay toolu_a toolu_b
} > "$T_REPLAY2"
OUT=$(run_hook "$(payload "s-replay2" "$T_REPLAY2")")
assert "2 edits replayed in an api-request-blob stay below the threshold" '[ -z "$OUT" ]'

T_REPLAY3="$TMP_DIR/replay3.jsonl"
{
  id_use toolu_a /tmp/a
  id_use toolu_b /tmp/b
  id_use toolu_c /tmp/c
  replay toolu_a toolu_b toolu_c
} > "$T_REPLAY3"
OUT=$(run_hook "$(payload "s-replay3" "$T_REPLAY3")")
assert "replayed edits are counted once" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "made 3 file edits"'

T_VERDANT="$TMP_DIR/verdant.jsonl"
{
  tool_use "mcp__verdant__write" "/tmp/a"
  tool_use "mcp__verdant__edit" "/tmp/b"
  tool_use "mcp__verdant__write" "/tmp/c"
} > "$T_VERDANT"
OUT=$(run_hook "$(payload "s-verdant" "$T_VERDANT")")
assert "3 verdant edits without wiki writes fires" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'

OUT=$(run_hook "$(payload "s-msg" "$T_EDITS")")
assert "block message never points at the generated top index" \
  '! printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "wiki/index.md"'

T_DONE="$TMP_DIR/done.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "/tmp/c"
  tool_use "Write" "$DEVLOG"
} > "$T_DONE"
OUT=$(run_hook "$(payload "s-done" "$T_DONE")")
assert "a devlog write alone satisfies a session with no new pages" '[ -z "$OUT" ]'

T_PAGE="$TMP_DIR/page.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "$DEVLOG"
  tool_use "Write" "$VAULT/wiki/projects/myproj/decisions/pick.md"
} > "$T_PAGE"
OUT=$(run_hook "$(payload "s-page" "$T_PAGE")")
assert "a new page without a project index update fires" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'
assert "the index block names the project index" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "$PINDEX"'
assert "the index block does not ask for the written devlog" \
  '! printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "devlog.md"'

{ cat "$T_PAGE"; tool_use "Edit" "$PINDEX"; } > "$TMP_DIR/page-indexed.jsonl"
OUT=$(run_hook "$(payload "s-page-indexed" "$TMP_DIR/page-indexed.jsonl")")
assert "a new page listed in the project index stays silent" '[ -z "$OUT" ]'

{ cat "$T_DONE"; tool_use "Read" "$VAULT/wiki/projects/myproj/decisions/old.md"; } > "$TMP_DIR/read-page.jsonl"
OUT=$(run_hook "$(payload "s-read-page" "$TMP_DIR/read-page.jsonl")")
assert "a wiki page that was only read does not demand an index line" '[ -z "$OUT" ]'

{ cat "$T_PAGE"; tool_use "Read" "$PINDEX"; } > "$TMP_DIR/read-index.jsonl"
OUT=$(run_hook "$(payload "s-read-index" "$TMP_DIR/read-index.jsonl")")
assert "reading the project index does not count as updating it" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "$PINDEX"'
assert "an index-only block does not claim the wiki went untouched" \
  '! printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "did not update the project wiki"'

{ cat "$T_EDITS"; tool_use "Read" "$DEVLOG"; } > "$TMP_DIR/read-devlog.jsonl"
OUT=$(run_hook "$(payload "s-read-devlog" "$TMP_DIR/read-devlog.jsonl")")
assert "reading the devlog does not count as writing it" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "$DEVLOG"'

OUT=$(run_hook "$(payload "s-parts" "$T_EDITS")")
assert "first stop blocks for the devlog" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "devlog.md"'
{ cat "$T_EDITS"; tool_use "Write" "$DEVLOG"; tool_use "Write" "$VAULT/wiki/projects/myproj/plans/p.md"; } > "$TMP_DIR/parts2.jsonl"
OUT=$(run_hook "$(payload "s-parts" "$TMP_DIR/parts2.jsonl")")
assert "a later new page still gets one index block" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "$PINDEX"'
OUT=$(run_hook "$(payload "s-parts" "$TMP_DIR/parts2.jsonl")")
assert "each part blocks only once per session" '[ -z "$OUT" ]'

printf '1\n' > "$STATE_DIR/s-legacy.count"
OUT=$(run_hook "$(payload "s-legacy" "$T_EDITS")")
assert "a pre-upgrade fired counter counts as every part fired" '[ -z "$OUT" ]'

assert "the stop hook regenerates the top index" \
  'grep -q "^generated: true" "$VAULT/wiki/index.md"'

git -C "$TMP_DIR" init -q wtmain
git -C "$TMP_DIR/wtmain" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP_DIR/wtmain" worktree add -q "$TMP_DIR/w-t8-seed" -b wt
OUT=$(WIKI_ENFORCE_STATE_DIR="$STATE_DIR" WIKI_VAULT="$VAULT" CLAUDE_PROJECT_DIR="$TMP_DIR/w-t8-seed" \
  bash "$HOOK" <<<"$(payload "s-worktree" "$T_EDITS")")
assert "a worktree session is held to the main checkout's devlog" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "projects/wtmain/devlog.md"'

printf 'WIKI_WORK_PROJECTS=myproj\n' > "$HARNESS_ENV"
OUT=$(run_hook "$(payload "s-routed" "$T_EDITS")")
assert "a personal session in a once-listed work project is held to the personal devlog" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "$VAULT/wiki/projects/myproj/devlog.md"'
: > "$HARNESS_ENV"

OUT=$(run_hook "$(payload "s-notranscript" "")")
assert "claude session without transcript stays silent" '[ -z "$OUT" ]'

RO_STATE="$TMP_DIR/ro-state"
mkdir -p "$RO_STATE"
chmod 555 "$RO_STATE"
OUT=$(WIKI_ENFORCE_STATE_DIR="$RO_STATE" WIKI_VAULT="$VAULT" \
  CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK" <<<"$(payload "s-rostate" "$T_EDITS")")
chmod 755 "$RO_STATE"
assert "unwritable state dir does not block" '[ -z "$OUT" ]'

# A verdant-routed project denies native Write and confines mcp__verdant__write
# to the project root, so a vault write can only go through a bash heredoc.
# The page lands but carries no file_path, which used to read as "not written".
T_HEREDOC="$TMP_DIR/heredoc.jsonl"
{
  tool_use "mcp__verdant__write" "/tmp/a"
  tool_use "mcp__verdant__write" "/tmp/b"
  tool_use "mcp__verdant__write" "/tmp/c"
  bash_use "mcp__verdant__bash" "cat > $VAULT/wiki/projects/myproj/devlog.md <<'EOF'
## [2026-07-31] work
EOF"
} > "$T_HEREDOC"
OUT=$(run_hook "$(payload "s-heredoc" "$T_HEREDOC")")
assert "heredoc writes through verdant bash satisfy the check" '[ -z "$OUT" ]'

# The nudge hook and this hook's own block message both name the wiki paths in
# prose. Matching the path as bare text would let the reminder satisfy the
# requirement it exists to enforce, so this must still fire.
T_PROSE="$TMP_DIR/prose.jsonl"
{
  tool_use "Write" "/tmp/a"
  tool_use "Edit" "/tmp/b"
  tool_use "Write" "/tmp/c"
  jq -cn --arg m "WIKI: write a devlog at $VAULT/wiki/projects/myproj/devlog.md then update $PINDEX, this is mandatory." \
    '{type:"user",message:{content:$m}}'
} > "$T_PROSE"
OUT=$(run_hook "$(payload "s-prose" "$T_PROSE")")
assert "prose naming the wiki paths does not satisfy the check" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'

# A command that builds the path from a variable never contains it literally,
# so mtime after session start is the only remaining signal.
T_MTIME="$TMP_DIR/mtime.jsonl"
{
  jq -cn --arg ts "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%S.000Z)" \
    '{type:"user",timestamp:$ts,message:{content:"go"}}'
  tool_use "mcp__verdant__write" "/tmp/a"
  tool_use "mcp__verdant__write" "/tmp/b"
  tool_use "mcp__verdant__write" "/tmp/c"
  bash_use "mcp__verdant__bash" 'cd "$WIKI_VAULT/wiki/projects/myproj" && cat > devlog.md <<EOF
built from a variable
EOF'
} > "$T_MTIME"
rm -rf "$VAULT/wiki/projects/myproj/decisions" "$VAULT/wiki/projects/myproj/plans"
touch "$VAULT/wiki/projects/myproj/devlog.md"
OUT=$(run_hook "$(payload "s-mtime" "$T_MTIME")")
assert "wiki pages touched after session start satisfy the check" '[ -z "$OUT" ]'

# Same transcript, but the pages predate the session: staleness must not pass.
T_STALE="$TMP_DIR/stale.jsonl"
{
  jq -cn --arg ts "$(date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%S.000Z)" \
    '{type:"user",timestamp:$ts,message:{content:"go"}}'
  tool_use "mcp__verdant__write" "/tmp/a"
  tool_use "mcp__verdant__write" "/tmp/b"
  tool_use "mcp__verdant__write" "/tmp/c"
} > "$T_STALE"
touch -d '-2 hours' "$VAULT/wiki/projects/myproj/devlog.md"
OUT=$(run_hook "$(payload "s-stale" "$T_STALE")")
assert "wiki pages older than session start still fire" \
  'printf "%s" "$OUT" | jq -e "(.hookSpecificOutput.hookEventName == \"Stop\") and (has(\"decision\") | not)" >/dev/null'
assert "stale devlog is reported as not updated, not missing" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -q "devlog.md exists but was not updated this session"'
assert "no Missing heading when every file exists" \
  '! printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qi "missing"'

mkdir -p "$VAULT/wiki/projects/myproj/spikes"
printf '# spike\n' > "$VAULT/wiki/projects/myproj/spikes/s.md"
touch "$VAULT/wiki/projects/myproj/devlog.md"
OUT=$(run_hook "$(payload "s-mtime-page" "$T_STALE")")
assert "a page changed after session start without an index update fires" \
  'printf "%s" "$OUT" | jq -r ".hookSpecificOutput.additionalContext" | grep -qF "$PINDEX"'

echo ""
echo "stop-wiki-enforce: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
