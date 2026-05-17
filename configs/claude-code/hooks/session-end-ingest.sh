#!/usr/bin/env bash
# SessionEnd hook: ingest conversation into second-brain (machine memory only)

# Recursion guard: prevent hooks from firing when invoked by background flush
[[ -n "${CLAUDE_INVOKED_BY:-}" ]] && echo '{}' && exit 0
SB_API="${SECOND_BRAIN_API:-http://127.0.0.1:7200}"

# Verify daemon is healthy before attempting ingest
if ! curl -sf "${SB_API}/v1/status" >/dev/null 2>&1; then
    echo '{}'
    exit 0
fi

# Non-blocking ingest into second-brain for machine recall
# Wiki maintenance happens during the session via the LLM, not at session end
if command -v sb >/dev/null 2>&1; then
    nohup sb ingest >/dev/null 2>&1 &
fi

echo '{}'
