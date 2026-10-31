#!/usr/bin/env bash
# Pushes "an agent session needs you" to ntfy after a grace delay that any
# sign of the user acting cancels. Knows nothing about any one harness: the
# adapters (attention-notify.sh, the opencode harness-attention.js plugin)
# feed it normalized JSON on stdin.
#
#   arm     {session, kind: block|done, harness, project, detail, delay?,
#            tool_use_id?, agent_id?, transcript?, agent_pid?}
#   cancel  {session, tool_use_id?, agent_id?, kind?}
#   fire <marker> <token>   run by the detached sleeper that arm starts
#
# One marker per session; a newer arm replaces its token, so only the newest
# state of a session can send. A sent block stays recorded until the user
# acts, so the "finished" push that follows an unanswered question is held.
set -uo pipefail

CORE="${BASH_SOURCE[0]}"
HOOK_DIR="$(cd "$(dirname "$CORE")" && pwd)"
# shellcheck source=load-harness-env.sh
source "$HOOK_DIR/load-harness-env.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/harness/attention"
LOG="$STATE_DIR/log"
LOG_KEEP=200

log() {
  local session="$1"
  shift
  mkdir -p "$STATE_DIR"
  printf '%s %s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "${session:0:8}" "$*" >> "$LOG"
  if (($(wc -l < "$LOG") > LOG_KEEP)); then
    tail -n "$LOG_KEEP" "$LOG" > "$LOG.$$" && mv "$LOG.$$" "$LOG"
  fi
}

load_config() {
  local name
  for name in NTFY_URL NTFY_TOPIC NTFY_TOKEN NTFY_BLOCK_DELAY NTFY_DONE_DELAY NTFY_DONE HARNESS_NOTIFY; do
    load_harness_var "$name"
  done
}

disabled_reason() {
  if [[ "${HARNESS_NOTIFY:-1}" == 0 ]]; then
    echo "disabled by HARNESS_NOTIFY=0"
  elif [[ -z "${NTFY_URL:-}" ]]; then
    echo "disabled: NTFY_URL unset"
  elif [[ -z "${NTFY_TOPIC:-}" ]]; then
    echo "disabled: NTFY_TOPIC unset"
  fi
}

marker_for() {
  printf '%s/%s.json' "$STATE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# Claude-style JSONL only. Answering a question or permission, pressing Esc
# and typing a prompt all append a user entry; assistant entries are left out
# because the message that triggered PreToolUse can land after arm reads.
user_entries() {
  if [[ -n "$1" && -f "$1" ]]; then
    grep -c '"type":"user"' "$1"
  else
    echo 0
  fi
}

spawn_fire() {
  local marker="$1" token="$2" delay="$3"
  # Closing every inherited descriptor so that the sleeper cannot hold the
  # hook's pipes open and keep the harness waiting on it.
  local script='for fd in /proc/$$/fd/*; do fd=${fd##*/}; ((fd > 2)) && eval "exec $fd>&-"; done 2>/dev/null
sleep "$1"; exec bash "$2" fire "$3" "$4"'
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$script" attention-fire "$delay" "$CORE" "$marker" "$token" </dev/null >/dev/null 2>&1 &
  else
    nohup bash -c "$script" attention-fire "$delay" "$CORE" "$marker" "$token" </dev/null >/dev/null 2>&1 &
  fi
}

arm() {
  local input session kind
  input=$(cat)
  session=$(jq -r '.session // empty' <<<"$input" 2>/dev/null) || return 0
  kind=$(jq -r '.kind // empty' <<<"$input")
  [[ -n "$session" && ("$kind" == block || "$kind" == done) ]] || return 0

  load_config
  local reason
  reason=$(disabled_reason)
  if [[ -n "$reason" ]]; then
    log "$session" "skip $kind: $reason"
    return 0
  fi
  if [[ "$kind" == done && "${NTFY_DONE:-1}" == 0 ]]; then
    log "$session" "skip done: finished-turn pushes are off (NTFY_DONE=0)"
    return 0
  fi

  mkdir -p "$STATE_DIR"
  find "$STATE_DIR" -name '*.json' -mtime +7 -delete 2>/dev/null
  local marker
  marker=$(marker_for "$session")
  if [[ "$kind" == done && -f "$marker" ]] && jq -e '.state == "sent" and .kind == "block"' "$marker" >/dev/null 2>&1; then
    log "$session" "skip done: block push still unanswered"
    return 0
  fi
  # Claude raises a generic permission_prompt about 7s into an AskUserQuestion
  # or ExitPlanMode dialog; replacing the pending block would swap the
  # question text for "needs your permission" and restart the delay.
  if [[ "$kind" == block && -f "$marker" ]] \
    && jq -e --argjson e "$input" '.kind == "block" and .tool_use_id != "" and ($e.tool_use_id // "") == ""
         and .agent_id == ($e.agent_id // "")' "$marker" >/dev/null 2>&1; then
    log "$session" "skip block: already waiting on that tool call"
    return 0
  fi

  local delay default_delay
  if [[ "$kind" == block ]]; then default_delay="${NTFY_BLOCK_DELAY:-60}"; else default_delay="${NTFY_DONE_DELAY:-60}"; fi
  delay=$(jq -r '.delay // empty' <<<"$input")
  [[ "$delay" =~ ^[0-9]+$ ]] || delay="$default_delay"
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=60

  local transcript anchor token
  transcript=$(jq -r '.transcript // empty' <<<"$input")
  anchor=$(user_entries "$transcript")
  token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')

  jq -c --arg token "$token" --argjson delay "$delay" --argjson anchor "$anchor" --arg at "$(date +%s)" '{
      session, kind,
      harness: (.harness // "Agent"), project: (.project // ""), detail: (.detail // ""),
      tool_use_id: (.tool_use_id // ""), agent_id: (.agent_id // ""),
      transcript: (.transcript // ""), agent_pid: ((.agent_pid // "") | tostring),
      token: $token, delay: $delay, anchor: $anchor, armed_at: $at, state: "armed"
    }' <<<"$input" > "$marker.$$" && mv "$marker.$$" "$marker"

  log "$session" "armed $kind in ${delay}s ($(jq -r '.harness // "Agent"' <<<"$input"), $(jq -r '.project // ""' <<<"$input"))"
  spawn_fire "$marker" "$token" "$delay"
}

# An event naming a tool call only clears a marker armed for that same call,
# or, for a marker with no call of its own, one armed by the same agent
# (main thread or subagent), so a subagent's tool finishing cannot cancel the
# main thread's pending question.
cancel() {
  local input session marker
  input=$(cat)
  session=$(jq -r '.session // empty' <<<"$input" 2>/dev/null) || return 0
  [[ -n "$session" ]] || return 0
  marker=$(marker_for "$session")
  [[ -f "$marker" ]] || return 0

  local verdict
  verdict=$(jq -r --slurpfile m "$marker" '
    $m[0] as $m
    | if (.kind // "") != "" and .kind != $m.kind then "keep"
      elif (.tool_use_id // "") == "" then "drop"
      elif $m.tool_use_id != "" then (if $m.tool_use_id == .tool_use_id then "drop" else "keep" end)
      elif $m.agent_id == (.agent_id // "") then "drop"
      else "keep" end' <<<"$input" 2>/dev/null)
  [[ "$verdict" == drop ]] || return 0

  local kind state
  kind=$(jq -r .kind "$marker" 2>/dev/null)
  state=$(jq -r .state "$marker" 2>/dev/null)
  rm -f "$marker"
  log "$session" "cancelled $kind ($state)"
}

curl_quote() {
  local s="${1//\\/\\\\}"
  printf '"%s"' "${s//\"/\\\"}"
}

send() {
  local marker_json="$1"
  local payload rc
  payload=$(mktemp)
  # Agent replies are markdown, which phone notifications show raw, so the
  # detail is reduced to plain lines with bullets kept as "•".
  jq -n --argjson m "$marker_json" --arg topic "$NTFY_TOPIC" --arg host "$(uname -n)" '
    def plain:
      gsub("\r"; "")
      | split("\n")
      | map(sub("^\\s+"; "") | sub("\\s+$"; "")
          | select(length > 0 and (test("^```") | not))
          | sub("^#+\\s*"; "")
          | sub("^[-*+]\\s+"; "• ")
          | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
          | gsub("\\*\\*|__|`"; "")
          | gsub("(?<![\\w*])[*_](?<t>[^*_\\s][^*_]*?)[*_](?![\\w*])"; "\(.t)")
          | gsub("[ \\t]+"; " "))
      | join("\n");
    ($m.kind == "block") as $block
    | ($m.detail | plain) as $d
    | (if $block then 300 else 160 end) as $limit
    | (if ($d | length) > $limit then $d[0:$limit - 1] + "…" else $d end) as $detail
    | {
        topic: $topic,
        title: ($m.harness + (if $block then " needs you" else " finished" end)
                + (if $m.project != "" then " · " + $m.project else "" end)),
        message: ((if $detail != "" then $detail + "\n" else "" end) + $host + " · " + $m.session[0:8]),
        priority: (if $block then 4 else 3 end),
        tags: [(if $block then "bell" else "white_check_mark" end)]
      }' > "$payload"

  local config
  config="url = $(curl_quote "$NTFY_URL")"
  if [[ -n "${NTFY_TOKEN:-}" ]]; then
    config+=$'\n'"header = $(curl_quote "Authorization: Bearer $NTFY_TOKEN")"
  fi
  curl -sf -m 10 -o /dev/null -K - --data-binary "@$payload" <<<"$config"
  rc=$?
  rm -f "$payload"
  return "$rc"
}

fire() {
  local marker="$1" token="$2"
  local session
  session=$(basename "$marker" .json)
  if [[ ! -f "$marker" ]]; then
    log "$session" "skip: cancelled before the delay ran out"
    return 0
  fi

  local m
  m=$(cat "$marker")
  if [[ "$(jq -r .token <<<"$m")" != "$token" ]]; then
    log "$session" "skip: superseded by a newer arm"
    return 0
  fi
  [[ "$(jq -r .state <<<"$m")" == armed ]] || return 0

  local kind pid transcript anchor
  kind=$(jq -r .kind <<<"$m")
  pid=$(jq -r .agent_pid <<<"$m")
  if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$marker"
    log "$session" "skip $kind: agent exited (pid $pid)"
    return 0
  fi

  transcript=$(jq -r .transcript <<<"$m")
  anchor=$(jq -r .anchor <<<"$m")
  if [[ "$kind" == block && -n "$transcript" ]] && (($(user_entries "$transcript") > anchor)); then
    rm -f "$marker"
    log "$session" "skip block: answered at the desk"
    return 0
  fi

  load_config
  local reason
  reason=$(disabled_reason)
  if [[ -n "$reason" ]]; then
    rm -f "$marker"
    log "$session" "skip $kind: $reason"
    return 0
  fi

  local rc=0
  send "$m" || rc=$?
  if ((rc != 0)); then
    rm -f "$marker"
    log "$session" "send-failed $kind (curl exit $rc)"
    return 0
  fi
  if [[ -f "$marker" && "$(jq -r .token "$marker" 2>/dev/null)" == "$token" ]]; then
    jq -c --arg at "$(date +%s)" '.state = "sent" | .sent_at = $at' "$marker" > "$marker.$$" && mv "$marker.$$" "$marker"
  fi
  log "$session" "sent $kind"
}

case "${1:-}" in
  arm) arm ;;
  cancel) cancel ;;
  fire) [[ $# -eq 3 ]] && fire "$2" "$3" ;;
  *)
    echo "usage: attention-core.sh arm|cancel < event.json, or fire <marker> <token>" >&2
    exit 2
    ;;
esac
exit 0
