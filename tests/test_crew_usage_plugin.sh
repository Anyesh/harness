#!/usr/bin/env bash
set -euo pipefail

unset HERDR_PANE_ID

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN="$REPO_ROOT/configs/opencode/plugins/harness-crew-usage.js"

PASS=0
FAIL=0
OUT=

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '        output: %s\n' "${OUT//$'\n'/$'\n        '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'command rm -rf "$TMP_DIR"' EXIT

export XDG_STATE_HOME="$TMP_DIR/state"
USAGE="$XDG_STATE_HOME/harness/usage/sessions"

# run_plugin <pane id or empty> <events json>: prints the session.get call count
# and whatever the plugin writes to stderr.
run_plugin() {
  OUT=$(HERDR_PANE_ID="$1" node --input-type=module -e '
    const [plugin, events] = process.argv.slice(1)
    if (!process.env.HERDR_PANE_ID) delete process.env.HERDR_PANE_ID
    let gets = 0
    const client = {
      session: {
        get: async ({ path }) => {
          gets++
          return { data: path.id.startsWith("child") ? { id: path.id, parentID: "root" } : { id: path.id } }
        },
      },
    }
    const mod = await import(plugin)
    const hooks = await Object.values(mod)[0]({ client, directory: "/tmp", worktree: "/tmp" })
    if (process.env.CONCURRENT) await Promise.all(JSON.parse(events).map((event) => hooks.event({ event })))
    else for (const event of JSON.parse(events)) await hooks.event({ event })
    console.log(`gets ${gets}`)
  ' "$PLUGIN" "$2" 2>&1) || true
}

# message <session> <role> <completed or null> <input> <read> <write>
message() {
  jq -nc --arg s "$1" --arg r "$2" --argjson c "$3" --argjson i "$4" --argjson cr "$5" --argjson cw "$6" '
    {type: "message.updated", properties: {info: {id: "m1", sessionID: $s, role: $r,
      time: ({created: 1} + (if $c == null then {} else {completed: $c} end)),
      tokens: {input: $i, output: 50, reasoning: 0, cache: {read: $cr, write: $cw}}}}}'
}

FILE="$USAGE/pane-w1_p3.json"

echo "finished root message"
run_plugin "w1:p3" "[$(message ses_a assistant 2 1200 30000 800)]"
assert "writes the pane's usage file with the pane id made safe" '[[ -f $FILE ]]'
assert "the file has the opencode profile, input plus cache tokens and no window" \
  '[[ $(jq -c . "$FILE" 2>/dev/null) == "{\"profile\":\"opencode\",\"context_tokens\":32000,\"context_window\":null}" ]]'
assert "no temp file is left behind" '[[ $(find "$USAGE" -type f 2>/dev/null | wc -l | tr -d " ") -eq 1 ]]'

echo "later message in the same session"
run_plugin "w1:p3" "[$(message ses_a assistant 2 1000 40000 0),$(message ses_a assistant 3 500 41000 100)]"
assert "the newest finished message replaces the figure" '[[ $(jq .context_tokens "$FILE" 2>/dev/null) -eq 41600 ]]'
assert "the parent check runs once per session" 'grep -qx "gets 1" <<<"$OUT"'

echo "concurrent events"
CONCURRENT=1 run_plugin "w1:p3" "[$(message ses_a assistant 2 1000000 400000 0),$(message ses_a assistant 3 5 0 0)]"
assert "two events handled at once leave one valid file and no error" \
  'jq -e ".context_tokens == 1400000 or .context_tokens == 5" "$FILE" >/dev/null 2>&1 && ! grep -q "^harness-crew-usage: " <<<"$OUT" && [[ $(find "$USAGE" -type f | wc -l | tr -d " ") -eq 1 ]]'

echo "messages that write nothing"
rm -rf "$USAGE"
run_plugin "w1:p3" "[$(message ses_a assistant null 1200 30000 800)]"
assert "an unfinished message writes nothing" '[[ ! -e $FILE ]]'
run_plugin "w1:p3" "[$(message child_1 assistant 2 1200 30000 800)]"
assert "a subagent session writes nothing" '[[ ! -e $FILE ]]'
run_plugin "w1:p3" "[$(message ses_a user 2 0 0 0)]"
assert "a user message writes nothing" '[[ ! -e $FILE ]]'
run_plugin "w1:p3" "[$(message ses_a assistant 2 0 0 0)]"
assert "a finished message with no tokens writes nothing" '[[ ! -e $FILE ]]'
rm -rf "$XDG_STATE_HOME"
run_plugin "" "[$(message ses_a assistant 2 1200 30000 800)]"
assert "no HERDR_PANE_ID writes nothing and asks nothing" '[[ ! -e $XDG_STATE_HOME/harness ]] && grep -qx "gets 0" <<<"$OUT"'

echo "write failure"
rm -rf "$XDG_STATE_HOME"
mkdir -p "$XDG_STATE_HOME/harness/usage"
touch "$XDG_STATE_HOME/harness/usage/sessions"
run_plugin "w1:p3" "[$(message ses_a assistant 2 1200 30000 800)]"
assert "a failed write is logged and does not throw" \
  'grep -q "^harness-crew-usage: " <<<"$OUT" && grep -qx "gets 1" <<<"$OUT"'

echo ""
echo "crew-usage-plugin: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
