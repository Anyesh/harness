#!/bin/bash
# Hook entry for the attention push: attention-notify.sh claude|codex|cursor.
# Maps the harness's hook payload to an arm or cancel call on
# attention-core.sh. Must print nothing and exit 0, because Cursor reads a
# stop or beforeSubmitPrompt hook's stdout as its answer.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness-project.sh
source "$HOOK_DIR/harness-project.sh"

claude_route() {
  jq -c '
    . as $e
    | (if .hook_event_name == "Notification" then
        if (.notification_type | IN("permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input")) then
          {action: "arm", kind: "block", detail: (.message // "")}
        elif .notification_type == "idle_prompt" then
          {action: "arm", kind: "done", delay: 0, detail: (.message // ""), last_text: true}
        else empty end
      elif .hook_event_name == "PreToolUse" then
        if .tool_name == "AskUserQuestion" then
          {action: "arm", kind: "block", tool_use_id: (.tool_use_id // ""),
           detail: (.tool_input.questions[0].question // "A question is waiting")}
        elif .tool_name == "ExitPlanMode" then
          {action: "arm", kind: "block", tool_use_id: (.tool_use_id // ""),
           detail: ("Plan waiting for approval: "
             + ((.tool_input.plan // "") | split("\n") | map(select(test("\\S"))) | (.[0] // "") | sub("^#+\\s*"; "")))}
        else empty end
      elif .hook_event_name | IN("UserPromptSubmit", "SessionEnd") then
        {action: "cancel"}
      elif .hook_event_name | IN("PostToolUse", "PostToolUseFailure") then
        {action: "cancel", tool_use_id: (.tool_use_id // "")}
      else empty end)
    | . + {session: ($e.session_id // ""), agent_id: ($e.agent_id // "")}
    | if .kind == "block" then . + {transcript: ($e.transcript_path // "")} else . end'
}

codex_route() {
  jq -c '
    . as $e
    | (if .hook_event_name == "PermissionRequest" then
        {action: "arm", kind: "block",
         detail: ([.tool_input.description?, (.tool_input.command? | if type == "array" then join(" ") else . end), .tool_name]
                  | map(select(type == "string" and length > 0)) | .[0] // "Permission requested")}
      elif .hook_event_name == "Stop" then
        {action: "arm", kind: "done", detail: (.last_assistant_message // "")}
      elif .hook_event_name | IN("UserPromptSubmit", "PostToolUse", "SessionEnd") then
        {action: "cancel"}
      else empty end)
    | . + {session: ($e.session_id // "")}'
}

cursor_route() {
  jq -c '
    . as $e
    | (if .hook_event_name == "stop" then
        if .status == "aborted" then empty
        elif .status == "error" then {action: "arm", kind: "done", detail: "Turn ended with an error"}
        else {action: "arm", kind: "done", detail: ""} end
      elif .hook_event_name | IN("beforeSubmitPrompt", "postToolUse", "sessionEnd") then
        {action: "cancel"}
      else empty end)
    | . + {session: ($e.conversation_id // $e.session_id // "")}'
}

harness_label() {
  case "$1" in
    claude) echo Claude ;;
    codex) echo Codex ;;
    cursor) echo Cursor ;;
  esac
}

# The pid the sender checks before pushing, so a session that was closed
# during the delay stays quiet. Claude exports CLAUDE_PID, but only Claude's
# own hooks may trust it because a Codex started from a Claude shell inherits
# it; elsewhere the hook runs under a shell or two below the agent process.
agent_pid() {
  if [[ "$1" == claude && -n "${CLAUDE_PID:-}" ]]; then
    echo "$CLAUDE_PID"
    return
  fi
  local pid="$PPID" ppid comm _
  for _ in 1 2 3 4 5 6; do
    read -r ppid comm < <(ps -o ppid=,comm= -p "$pid" 2>/dev/null) || return
    case "$comm" in
      bash | sh | zsh | dash | fish | env | timeout | nohup) pid="$ppid" ;;
      *)
        echo "$pid"
        return
        ;;
    esac
  done
}

project_label() {
  local input="$1" cwd root
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  if [[ -n "$cwd" && -d "$cwd" ]]; then
    root=$(cd "$cwd" && harness_repo_root "$input")
  else
    root=$(harness_repo_root "$input")
  fi
  harness_project_slug "$root"
}

last_assistant_text() {
  [[ -n "$1" && -f "$1" ]] || return 0
  tail -n 400 "$1" \
    | jq -Rr 'fromjson? | select(.type == "assistant" and (.isSidechain | not))
        | [.message.content[]? | select(.type == "text") | .text] | join(" ")
        | select(length > 0) | @json' 2>/dev/null \
    | tail -n 1 | jq -r . 2>/dev/null
}

main() {
  local harness="${1:-}" input route action label
  label=$(harness_label "$harness")
  [[ -n "$label" ]] || return 0
  # Undocumented: Claude sets this to 0 for headless `claude -p` runs, which
  # nobody is watching, and to 1 for interactive sessions.
  [[ "$harness" == claude && "${CLAUDE_CODE_SESSION_ATTENDED:-}" == 0 ]] && return 0

  input=$(cat)
  route=$("${harness}_route" <<<"$input" 2>/dev/null) || return 0
  [[ -n "$route" ]] || return 0
  action=$(jq -r .action <<<"$route")

  if [[ "$action" == cancel ]]; then
    bash "$HOOK_DIR/attention-core.sh" cancel <<<"$route"
    return 0
  fi

  local detail=""
  if [[ "$(jq -r '.last_text // false' <<<"$route")" == true ]]; then
    detail=$(last_assistant_text "$(jq -r '.transcript_path // empty' <<<"$input")")
  fi
  jq -c --arg harness "$label" --arg project "$(project_label "$input")" --arg pid "$(agent_pid "$harness")" --arg detail "$detail" '
      del(.action, .last_text)
      | . + {harness: $harness, project: $project, agent_pid: $pid}
      | if $detail != "" then .detail = $detail else . end' <<<"$route" \
    | bash "$HOOK_DIR/attention-core.sh" arm
}

main "$@" >/dev/null
exit 0
