#!/usr/bin/env bash
# SessionEnd hook: ingest conversation into second-brain

SB_API="${SECOND_BRAIN_API:-http://127.0.0.1:7200}"

# Verify daemon is healthy before attempting ingest
if ! curl -sf "${SB_API}/v1/status" >/dev/null 2>&1; then
    exit 0
fi

# Non-blocking ingest — don't delay session exit
if command -v sb >/dev/null 2>&1; then
    nohup sb ingest >/dev/null 2>&1 &
fi

echo '{}'
