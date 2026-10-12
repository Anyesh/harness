#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$REPO_ROOT/configs/shared/hooks"
CORE="$HOOKS/attention-core.sh"
NOTIFY="$HOOKS/attention-notify.sh"

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
# Sleepers spawned by arm carry the marker path on their command line, so
# matching TMP_DIR reaps them without touching anything else.
cleanup() {
  pkill -f "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

STATE="$TMP_DIR/state"
ATT="$STATE/harness/attention"
STUB="$TMP_DIR/bin"
CALLS="$TMP_DIR/calls"
PROJECT="$TMP_DIR/widget-shop"
ENV_FILE="$TMP_DIR/harness.env"
TRANSCRIPT="$TMP_DIR/transcript.jsonl"
mkdir -p "$STUB" "$CALLS" "$PROJECT"
git -C "$PROJECT" init -q

cat > "$STUB/curl" <<'EOF'
#!/bin/bash
n=$(ls "$STUB_CALLS" | wc -l)
dir="$STUB_CALLS/$n"
mkdir -p "$dir"
printf '%s\n' "$@" > "$dir/argv"
cat > "$dir/config"
prev=""
for a in "$@"; do
  [[ "$prev" == "--data-binary" ]] && cp "${a#@}" "$dir/body"
  prev="$a"
done
[[ -n "${STUB_CURL_FAIL:-}" ]] && exit 22
exit 0
EOF
chmod +x "$STUB/curl"

write_env() {
  : > "$ENV_FILE"
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$ENV_FILE"; done
}
write_env NTFY_URL=https://ntfy.example.test NTFY_TOPIC=agents NTFY_TOKEN=tk_secret123

# The developer's own shell may export real ntfy settings and Claude's
# attended flag, so every run starts from a cleared environment.
run_env() {
  env -u NTFY_URL -u NTFY_TOPIC -u NTFY_TOKEN -u HARNESS_NOTIFY \
    -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_PROJECT_DIR -u CURSOR_PROJECT_DIR \
    -u NTFY_BLOCK_DELAY -u NTFY_DONE_DELAY \
    HARNESS_ENV="$ENV_FILE" XDG_STATE_HOME="$STATE" PATH="$STUB:$PATH" STUB_CALLS="$CALLS" \
    NTFY_BLOCK_DELAY=600 NTFY_DONE_DELAY=600 CLAUDE_PID=$$ "$@"
}

notify() {
  local harness="$1" json="$2"
  shift 2
  run_env "$@" bash "$NOTIFY" "$harness" <<<"$json"
}

marker() { printf '%s/%s.json' "$ATT" "$1"; }
token_of() { jq -r .token "$(marker "$1")"; }
fire() { run_env "$@" bash "$CORE" fire "$(marker "$S")" "$TOKEN"; }
calls() { ls "$CALLS" | wc -l; }
last_call() { printf '%s/%s' "$CALLS" "$(($(calls) - 1))"; }
body_field() { jq -r "$1" "$(last_call)/body"; }
log_has() { grep -q -- "$1" "$ATT/log"; }

printf '{"type":"user","message":{"role":"user","content":"ship it"}}\n' > "$TRANSCRIPT"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Shipped the widget, tests pass."}]}}\n' >> "$TRANSCRIPT"
printf '{"type":"system","subtype":"turn_duration"}\n' >> "$TRANSCRIPT"

ask_json() {
  jq -nc --arg s "$1" --arg t "$TRANSCRIPT" --arg cwd "$PROJECT" --arg id "${2:-tu-ask}" \
    '{session_id:$s, hook_event_name:"PreToolUse", tool_name:"AskUserQuestion", tool_use_id:$id,
      tool_input:{questions:[{question:"Which database should the widget use?"}]},
      transcript_path:$t, cwd:$cwd}'
}

echo ""

S=claude-ask
notify claude "$(ask_json $S)"
assert "AskUserQuestion arms a block marker" '[ "$(jq -r .kind "$(marker $S)")" = block ]'
TOKEN=$(token_of $S)
BEFORE=$(calls)
fire
assert "unanswered question sends one push" '[ "$(calls)" -eq $((BEFORE + 1)) ]'
assert "block push is priority 4" '[ "$(body_field .priority)" = 4 ]'
assert "block push carries the question" 'body_field .message | grep -q "Which database should the widget use?"'
assert "block push title names harness and project" 'body_field .title | grep -q "Claude needs you · widget-shop"'
assert "push goes to the configured topic" '[ "$(body_field .topic)" = agents ]'
assert "push body ends with host and short session" 'body_field .message | grep -q "$(uname -n) · claude-a"'
assert "token reaches curl through its config" 'grep -q "Authorization: Bearer tk_secret123" "$(last_call)/config"'
assert "url reaches curl through its config" 'grep -q "url = \"https://ntfy.example.test\"" "$(last_call)/config"'
assert "token never appears on argv" '! grep -q tk_secret123 "$(last_call)/argv"'
assert "log records the send" 'log_has "sent block"'

S=claude-plan
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PreToolUse", tool_name:"ExitPlanMode", tool_use_id:"tu-plan", tool_input:{plan:"# Plan: rebuild the cache\n\nsteps"}}')"
assert "ExitPlanMode arms a block with the plan title" 'jq -r .detail "$(marker $S)" | grep -q "rebuild the cache"'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUseFailure", tool_use_id:"tu-plan"}')"
assert "rejected plan (PostToolUseFailure) cancels" '[ ! -f "$(marker $S)" ]'

S=claude-cancel
notify claude "$(ask_json $S)"
TOKEN=$(token_of $S)
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"UserPromptSubmit", prompt:"never mind"}')"
assert "prompt submit removes the marker" '[ ! -f "$(marker $S)" ]'
BEFORE=$(calls)
fire
assert "fire after cancel sends nothing" '[ "$(calls)" -eq "$BEFORE" ]'
assert "log records the cancel" 'log_has "cancelled block"'

S=claude-sub
notify claude "$(ask_json $S tu-main)"
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUse", tool_use_id:"tu-other", agent_id:"agent-7"}')"
assert "subagent PostToolUse keeps the main block" '[ -f "$(marker $S)" ]'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUse", tool_use_id:"tu-elsewhere"}')"
assert "PostToolUse of another tool keeps a question block" '[ -f "$(marker $S)" ]'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUse", tool_use_id:"tu-main"}')"
assert "PostToolUse with the matching tool_use_id cancels" '[ ! -f "$(marker $S)" ]'

S=claude-perm
perm_json() {
  jq -nc --arg s $S --arg a "${1:-}" '{session_id:$s, hook_event_name:"Notification", notification_type:"permission_prompt",
    message:"Claude needs your permission to use Bash"} + (if $a == "" then {} else {agent_id:$a} end)'
}
notify claude "$(perm_json)"
assert "permission_prompt arms a block" '[ "$(jq -r .detail "$(marker $S)")" = "Claude needs your permission to use Bash" ]'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUse", tool_use_id:"tu-x", agent_id:"agent-7"}')"
assert "subagent PostToolUse keeps a main-thread permission block" '[ -f "$(marker $S)" ]'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUse", tool_use_id:"tu-x"}')"
assert "main-thread PostToolUse cancels the permission block" '[ ! -f "$(marker $S)" ]'
notify claude "$(perm_json agent-7)"
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"PostToolUse", tool_use_id:"tu-y", agent_id:"agent-7"}')"
assert "a subagent's own PostToolUse cancels its permission block" '[ ! -f "$(marker $S)" ]'

S=claude-replace
notify claude "$(ask_json $S)"
TOKEN=$(token_of $S)
notify claude "$(ask_json $S)"
BEFORE=$(calls)
fire
assert "replaced token does not send" '[ "$(calls)" -eq "$BEFORE" ]'
assert "log records the superseded fire" 'log_has "superseded"'

S=claude-dead
sleep 0 &
DEAD=$!
wait "$DEAD"
notify claude "$(ask_json $S)" CLAUDE_PID=$DEAD
TOKEN=$(token_of $S)
BEFORE=$(calls)
fire
assert "dead agent pid does not send" '[ "$(calls)" -eq "$BEFORE" ]'
assert "log records the exited agent" 'log_has "agent exited"'

S=claude-grown
notify claude "$(ask_json $S)"
TOKEN=$(token_of $S)
printf '{"type":"progress","data":{}}\n' >> "$TRANSCRIPT"
BEFORE=$(calls)
fire
assert "non-conversation transcript lines do not count as an answer" '[ "$(calls)" -eq $((BEFORE + 1)) ]'
notify claude "$(ask_json $S)"
TOKEN=$(token_of $S)
printf '{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}\n' >> "$TRANSCRIPT"
BEFORE=$(calls)
fire
assert "transcript user entry after arming skips the block" '[ "$(calls)" -eq "$BEFORE" ]'
assert "log records the answered skip" 'log_has "answered"'
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Shipped the widget, tests pass."}]}}\n' >> "$TRANSCRIPT"

S=claude-idle
BEFORE=$(calls)
notify claude "$(jq -nc --arg s $S --arg t "$TRANSCRIPT" --arg cwd "$PROJECT" \
  '{session_id:$s, hook_event_name:"Notification", notification_type:"idle_prompt", message:"Claude is waiting for your input", transcript_path:$t, cwd:$cwd}')"
for _ in $(seq 50); do [ "$(calls)" -gt "$BEFORE" ] && break; sleep 0.1; done
assert "idle_prompt pushes with no extra delay" '[ "$(calls)" -eq $((BEFORE + 1)) ]'
assert "done push is priority 3" '[ "$(body_field .priority)" = 3 ]'
assert "done push carries the last assistant text" 'body_field .message | grep -q "Shipped the widget, tests pass."'
assert "done push title says finished" 'body_field .title | grep -q "Claude finished · widget-shop"'

S=claude-ask
assert "sent block stays recorded until the user acts" '[ "$(jq -r .state "$(marker $S)")" = sent ]'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"Notification", notification_type:"idle_prompt", message:"waiting"}')"
assert "idle_prompt after an unanswered block push is skipped" '[ "$(jq -r .kind "$(marker $S)")" = block ]'
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"SessionEnd", reason:"exit"}')"
assert "SessionEnd clears the sent record" '[ ! -f "$(marker $S)" ]'

S=claude-auth
notify claude "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"Notification", notification_type:"auth_success", message:"ok"}')"
assert "auth_success arms nothing" '[ ! -f "$(marker $S)" ]'

S=claude-headless
notify claude "$(ask_json $S)" CLAUDE_CODE_SESSION_ATTENDED=0
assert "headless claude -p arms nothing" '[ ! -f "$(marker $S)" ]'
notify claude "$(ask_json $S)" CLAUDE_CODE_SESSION_ATTENDED=1
assert "attended claude arms" '[ -f "$(marker $S)" ]'

S=claude-off
notify claude "$(ask_json $S)" HARNESS_NOTIFY=0
assert "HARNESS_NOTIFY=0 arms nothing" '[ ! -f "$(marker $S)" ]'
assert "log records the disabled skip" 'log_has "disabled"'

write_env NTFY_TOPIC=agents
S=claude-nourl
notify claude "$(ask_json $S)"
assert "missing NTFY_URL arms nothing" '[ ! -f "$(marker $S)" ]'
write_env NTFY_URL=https://ntfy.example.test
S=claude-notopic
notify claude "$(ask_json $S)"
assert "missing NTFY_TOPIC arms nothing" '[ ! -f "$(marker $S)" ]'

write_env NTFY_URL=https://ntfy.example.test NTFY_TOPIC=agents
S=codex-perm
notify codex "$(jq -nc --arg s $S --arg cwd "$PROJECT" '{session_id:$s, hook_event_name:"PermissionRequest", tool_name:"Bash",
  tool_input:{command:["rm","-rf","build"], description:"Remove the build directory"}, cwd:$cwd}')"
TOKEN=$(token_of $S)
fire
assert "codex PermissionRequest pushes a block" '[ "$(body_field .priority)" = 4 ]'
assert "codex block carries the description" 'body_field .message | grep -q "Remove the build directory"'
assert "codex title names Codex" 'body_field .title | grep -q "Codex needs you · widget-shop"'
assert "no token configured means no Authorization line" '! grep -q Authorization "$(last_call)/config"'

S=codex-stop
notify codex "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"Stop", last_assistant_message:"Refactor landed on main."}')"
assert "codex Stop arms done with the default delay" '[ "$(jq -r .delay "$(marker $S)")" = 600 ]'
TOKEN=$(token_of $S)
fire
assert "codex Stop pushes done" '[ "$(body_field .priority)" = 3 ]'
assert "codex done carries the last message" 'body_field .message | grep -q "Refactor landed on main."'
notify codex "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"UserPromptSubmit", prompt:"next"}')"
assert "codex UserPromptSubmit clears the session" '[ ! -f "$(marker $S)" ]'

S=cursor-abort
notify cursor "$(jq -nc --arg s $S '{conversation_id:$s, hook_event_name:"stop", status:"aborted"}')"
assert "cursor aborted stop arms nothing" '[ ! -f "$(marker $S)" ]'
S=cursor-done
notify cursor "$(jq -nc --arg s $S --arg w "$PROJECT" '{conversation_id:$s, hook_event_name:"stop", status:"completed", workspace_roots:[$w]}')"
assert "cursor completed stop arms done" '[ "$(jq -r .kind "$(marker $S)")" = done ]'
assert "cursor project comes from workspace_roots" '[ "$(jq -r .project "$(marker $S)")" = widget-shop ]'
notify cursor "$(jq -nc --arg s $S '{conversation_id:$s, hook_event_name:"beforeSubmitPrompt", prompt:"more"}')"
assert "cursor beforeSubmitPrompt cancels" '[ ! -f "$(marker $S)" ]'

OUT=$(notify claude "$(ask_json claude-quiet)"; echo "rc=$?")
assert "hook prints nothing and exits 0" '[ "$OUT" = "rc=0" ]'
OUT=$(notify claude 'not json'; echo "rc=$?")
assert "malformed input still exits 0 silently" '[ "$OUT" = "rc=0" ]'

S=send-fail
notify codex "$(jq -nc --arg s $S '{session_id:$s, hook_event_name:"Stop", last_assistant_message:"x"}')"
TOKEN=$(token_of $S)
fire STUB_CURL_FAIL=1
assert "failed send is logged" 'log_has "send-failed"'
assert "failed send drops the marker" '[ ! -f "$(marker $S)" ]'

for i in $(seq 260); do printf 'filler %s\n' "$i" >> "$ATT/log"; done
notify codex "$(jq -nc '{session_id:"trim", hook_event_name:"Stop", last_assistant_message:"x"}')"
assert "log is trimmed to its last 200 lines" '[ "$(wc -l < "$ATT/log")" -le 200 ]'


echo ""
echo "attention-notify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
