#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --url URL --model MODEL --format ollama|openai --prompt PROMPT" >&2
  exit 1
}

URL="" MODEL="" FORMAT="" PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)    URL="$2";    shift 2 ;;
    --model)  MODEL="$2";  shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$URL" || -z "$MODEL" || -z "$FORMAT" || -z "$PROMPT" ]] && usage

PROBE_PORTS=(8080 8081 11434 8000 8088)

resolve_url() {
  local base="$1"
  local host
  host=$(python3 -c "from urllib.parse import urlparse; u=urlparse('$base'); print(u.scheme+'://'+u.hostname)")

  if curl -sf --max-time 3 "$base/health" > /dev/null 2>&1 || \
     curl -sf --max-time 3 "$base/api/tags" > /dev/null 2>&1 || \
     curl -sf --max-time 3 "$base/v1/models" > /dev/null 2>&1; then
    echo "$base"
    return 0
  fi

  for port in "${PROBE_PORTS[@]}"; do
    local candidate="$host:$port"
    if curl -sf --max-time 3 "$candidate/health" > /dev/null 2>&1 || \
       curl -sf --max-time 3 "$candidate/api/tags" > /dev/null 2>&1 || \
       curl -sf --max-time 3 "$candidate/v1/models" > /dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  echo ""
  return 1
}

RESOLVED=$(resolve_url "$URL") || { echo "No LLM server reachable at $URL or nearby ports" >&2; exit 1; }

ESCAPED=$(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
MODEL_J=$(printf '%s' "$MODEL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

if [[ "$FORMAT" == "ollama" ]]; then
  curl -sf --max-time 120 \
    "$RESOLVED/api/generate" \
    -H "Content-Type: application/json" \
    -d "{\"model\": $MODEL_J, \"prompt\": $ESCAPED, \"stream\": false}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("response",""))'
elif [[ "$FORMAT" == "openai" ]]; then
  API_KEY="${OPENAI_API_KEY:-none}"
  curl -sf --max-time 120 \
    "$RESOLVED/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"model\": $MODEL_J, \"messages\": [{\"role\": \"user\", \"content\": $ESCAPED}]}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
else
  echo "Unknown format: $FORMAT (use ollama or openai)" >&2
  exit 1
fi
