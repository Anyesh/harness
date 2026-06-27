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

ESCAPED=$(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

if [[ "$FORMAT" == "ollama" ]]; then
  curl -sf --max-time 120 \
    "$URL/api/generate" \
    -H "Content-Type: application/json" \
    -d "{\"model\": $( printf '%s' "$MODEL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"prompt\": $ESCAPED, \"stream\": false}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("response",""))'
elif [[ "$FORMAT" == "openai" ]]; then
  API_KEY="${OPENAI_API_KEY:-none}"
  curl -sf --max-time 120 \
    "$URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{\"model\": $(printf '%s' "$MODEL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), \"messages\": [{\"role\": \"user\", \"content\": $ESCAPED}]}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
else
  echo "Unknown format: $FORMAT (use ollama or openai)" >&2
  exit 1
fi
