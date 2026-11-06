#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/configs/shared/hooks/session-end-ingest.sh"
PLUGIN="$REPO_ROOT/configs/opencode/plugins/harness-second-brain.js"

PASS=0
FAIL=0
OUT=

assert() {
    local name="$1"
    if eval "$2"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n' "$name"
        printf '        output: %s\n' "${OUT//$'\n'/$'\n        '}"
        FAIL=$((FAIL + 1))
    fi
}

TMP_DIR=$(mktemp -d)
SERVER_PID=
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    command rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# The real daemon's /v1/status builds a full stats report and takes seconds,
# so the fake makes it slower than any exit budget while /health stays instant.
node -e '
    const http = require("http")
    const server = http.createServer((req, res) => {
        if (req.url === "/health") return res.end("ok")
        if (req.url === "/v1/status") return setTimeout(() => res.end("{}"), 8000)
        res.statusCode = 401
        res.end()
    })
    server.listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[1], String(server.address().port)))
' "$TMP_DIR/port" &
SERVER_PID=$!
for _ in $(seq 50); do
    [[ -s "$TMP_DIR/port" ]] && break
    sleep 0.1
done
LIVE_API="http://127.0.0.1:$(cat "$TMP_DIR/port")"
DEAD_API="http://127.0.0.1:9"

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/sb" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$TMP_DIR/sb-calls"
EOF
chmod +x "$TMP_DIR/bin/sb"

wait_for_call() {
    for _ in $(seq 20); do
        [[ -s "$TMP_DIR/sb-calls" ]] && return 0
        sleep 0.1
    done
    return 1
}

# run_hook <api>: sets OUT and ELAPSED_MS
run_hook() {
    : >"$TMP_DIR/sb-calls"
    local start end
    start=$(date +%s%N)
    OUT=$(echo '{}' | env -u CLAUDE_INVOKED_BY SECOND_BRAIN_API="$1" PATH="$TMP_DIR/bin:$PATH" bash "$HOOK" 2>&1) || true
    end=$(date +%s%N)
    ELAPSED_MS=$(((end - start) / 1000000))
}

echo "session-end-ingest.sh"
run_hook "$LIVE_API"
assert "live daemon: hook returns within 2 s" '((ELAPSED_MS < 2000))'
assert "live daemon: hook prints {}" '[[ "$OUT" == "{}" ]]'
assert "live daemon: hook starts sb ingest" 'wait_for_call && grep -qx ingest "$TMP_DIR/sb-calls"'

run_hook "$DEAD_API"
assert "dead daemon: hook returns within 2 s" '((ELAPSED_MS < 2000))'
assert "dead daemon: hook skips sb ingest" '! wait_for_call'

# run_plugin <api>: sets OUT to the commands the plugin ran and ELAPSED_MS
run_plugin() {
    local start end
    start=$(date +%s%N)
    OUT=$(SECOND_BRAIN_API="$1" node --input-type=module -e '
        const calls = []
        const $ = (strings, ...values) => {
            calls.push(String.raw({ raw: strings }, ...values))
            const p = Promise.resolve()
            p.nothrow = () => p
            p.quiet = () => p
            return p
        }
        const mod = await import(process.argv[1])
        const hooks = await Object.values(mod)[0]({ $ })
        await hooks.event({ event: { type: "session.idle" } })
        console.log(calls.join("\n"))
    ' "$PLUGIN" 2>&1) || true
    end=$(date +%s%N)
    ELAPSED_MS=$(((end - start) / 1000000))
}

echo "harness-second-brain.js"
run_plugin "$LIVE_API"
assert "live daemon: plugin runs sb ingest" '[[ "$OUT" == "sb ingest" ]]'
assert "live daemon: plugin finishes within 2 s" '((ELAPSED_MS < 2000))'

run_plugin "$DEAD_API"
assert "dead daemon: plugin skips sb ingest" '[[ -z "$OUT" ]]'

echo ""
echo "Session-end ingest: $((PASS + FAIL)) total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
