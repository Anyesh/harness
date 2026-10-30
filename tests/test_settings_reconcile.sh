#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MERGE="$REPO_ROOT/lib/json_merge3.py"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local name="$1"
    TOTAL=$((TOTAL + 1))
    if eval "$2"; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

J="$TMP_DIR/json"
mkdir -p "$J"

merge() {
    local base="$1" ours="$2" theirs="$3"
    printf '%s' "$ours" > "$J/ours.json"
    printf '%s' "$theirs" > "$J/theirs.json"
    if [[ -n "$base" ]]; then
        printf '%s' "$base" > "$J/base.json"
        python3 "$MERGE" "$J/ours.json" "$J/theirs.json" "$J/out.json" "$J/base.json"
    else
        python3 "$MERGE" "$J/ours.json" "$J/theirs.json" "$J/out.json"
    fi
}
out() { jq -c "$1" "$J/out.json"; }

echo ""
echo "=== merge rules ==="
echo ""

conflicts=$(merge '' \
    '{"env":{"WIKI_VAULT":"/v"},"permissions":{"defaultMode":"auto","allow":[]}}' \
    '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"},"model":"arn:x","permissions":{"defaultMode":"default","allow":["Bash(aws:*)"]}}')
assert "no base: local-only keys survive" '[[ "$(out ".env")" == "{\"WIKI_VAULT\":\"/v\",\"CLAUDE_CODE_USE_BEDROCK\":\"1\"}" && "$(out .model)" == "\"arn:x\"" ]]'
assert "no base: arrays union" '[[ "$(out .permissions.allow)" == "[\"Bash(aws:*)\"]" ]]'
assert "no base: a differing scalar keeps the local value" '[[ "$(out .permissions.defaultMode)" == "\"default\"" ]]'
assert "no base: the differing scalar is reported with both values" '[[ "$conflicts" == $'"'"'permissions.defaultMode\t"default"\t"auto"'"'"' ]]'

conflicts=$(merge '{"a":1,"b":1}' '{"a":2,"b":1}' '{"a":1,"b":3}')
assert "harness change applies where the local value is the base" '[[ "$(out .a)" == "2" ]]'
assert "local change survives where the harness value is the base" '[[ "$(out .b)" == "3" && -z "$conflicts" ]]'

conflicts=$(merge '{"a":1}' '{"a":2}' '{"a":3}')
assert "both sides changed: local wins" '[[ "$(out .a)" == "3" ]]'
assert "both sides changed: reported" '[[ "$conflicts" == $'"'"'a\t3\t2'"'"' ]]'

merge '{"h":[{"c":"old"},{"c":"keep"}]}' '{"h":[{"c":"keep"},{"c":"new"}]}' '{"h":[{"c":"old"},{"c":"keep"},{"c":"mine"}]}' > /dev/null
assert "arrays: harness order, harness removals dropped, local additions appended" '[[ "$(out .h)" == "[{\"c\":\"keep\"},{\"c\":\"new\"},{\"c\":\"mine\"}]" ]]'

merge '{"h":[{"c":"keep"}],"k":1}' '{"h":[{"c":"keep"}],"k":1}' '{"h":[]}' > /dev/null
assert "harness entries removed locally come back" '[[ "$(out .h)" == "[{\"c\":\"keep\"}]" && "$(out .k)" == "1" ]]'

conflicts=$(merge '{"gone":1,"edited":1}' '{}' '{"gone":1,"edited":2}')
assert "key the harness dropped is removed when untouched locally" '[[ "$(out "has(\"gone\")")" == "false" ]]'
assert "key the harness dropped but edited locally is kept and reported" '[[ "$(out .edited)" == "2" && "$conflicts" == $'"'"'edited\t2\t(removed)'"'"' ]]'

printf '{"a":1,}' > "$J/theirs.json"
printf '{"a":1}' > "$J/ours.json"
rc=0
python3 "$MERGE" "$J/ours.json" "$J/theirs.json" "$J/out2.json" 2>/dev/null || rc=$?
assert "local file that is not strict JSON exits 3 and writes nothing" '[[ $rc -eq 3 && ! -e "$J/out2.json" ]]'

echo ""
echo "=== install ==="
echo ""

# A copy of the working tree, because the base rebuild reads the template at the
# manifest's repo_commit and the test needs commits of its own.
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
(cd "$REPO_ROOT" && git ls-files -z --cached --others --exclude-standard | xargs -0 cp --parents -t "$REPO")
commit() {
    git -C "$REPO" add -A
    LEAKGUARD_SKIP=1 git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null commit -qm "$1"
}
git -C "$REPO" init -q
commit snapshot

H="$TMP_DIR/home"
mkdir -p "$H/.claude" "$H/.local/bin"
printf 'WIKI_VAULT=%s/vault\n' "$TMP_DIR" > "$H/.harness.env"
for tool in claude sb; do
    printf '#!/bin/sh\necho "mock %s"\n' "$tool" > "$H/.local/bin/$tool"
    chmod +x "$H/.local/bin/$tool"
done
S="$H/.claude/settings.json"
BASE_DIR="$H/.harness-merge-base"

harness() {
    HOME="$H" \
    XDG_CONFIG_HOME="$H/.config" \
    HARNESS_ENV="$H/.harness.env" \
    HARNESS_MANIFEST="$H/manifest.json" \
    HARNESS_BACKUP_DIR="$H/backups" \
    PATH="$H/.local/bin:$PATH" \
    bash "$REPO/install.sh" --only claude --no-plugins "$@" 2>&1
}
edit_json() {
    local tmp
    tmp=$(mktemp)
    jq "$1" "$2" > "$tmp" && mv "$tmp" "$2"
}
hook_count() { jq "[.hooks[][].hooks[] | select(.command | contains(\"$1\"))] | length" "$S"; }

harness > /dev/null
assert "first install deploys settings.json" '[[ -f "$S" && "$(hook_count cost-guard.sh)" == "1" ]]'
assert "first install stores the merge base" '[[ -n "$(ls -A "$BASE_DIR" 2>/dev/null)" ]]'

edit_json '.env.CLAUDE_CODE_USE_BEDROCK = "1" | .model = "arn:work" | .permissions.allow += ["Bash(aws:*)"] | .permissions.defaultMode = "default" | .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"work-guard.sh"}]}]' "$S"
second=$(harness)
assert "work keys survive a re-install" '[[ "$(jq -r .env.CLAUDE_CODE_USE_BEDROCK "$S")" == "1" && "$(jq -r .model "$S")" == "arn:work" && "$(jq -c .permissions.allow "$S")" == "[\"Bash(aws:*)\"]" ]]'
assert "work hook survives next to the harness hooks" '[[ "$(hook_count work-guard.sh)" == "1" && "$(hook_count cost-guard.sh)" == "1" ]]'
assert "a local value the harness did not change is kept silently" '[[ "$(jq -r .permissions.defaultMode "$S")" == "default" ]] && ! grep -q "conflict" <<<"$second"'

H_TMPL="$REPO/configs/claude-code/settings.json.tmpl"
edit_json '.permissions.defaultMode = "plan"' "$H_TMPL"
commit "harness changes defaultMode"
third=$(harness)
assert "a value both sides changed keeps the local one" '[[ "$(jq -r .permissions.defaultMode "$S")" == "default" ]]'
assert "the install prints the conflict with both values" 'grep -q "permissions.defaultMode" <<<"$third" && grep -qF "\"plan\"" <<<"$third"'
fourth=$(harness)
assert "a reported conflict is not repeated on the next install" '! grep -q "permissions.defaultMode" <<<"$fourth"'

edit_json '.hooks.PreToolUse += [{"matcher":"Read","hooks":[{"type":"command","command":"stale-hook.sh"}]}]' "$H_TMPL"
commit "harness adds a hook"
harness > /dev/null
assert "a hook the harness adds is merged in" '[[ "$(hook_count stale-hook.sh)" == "1" ]]'
git -C "$REPO" checkout -q HEAD~1 -- configs/claude-code/settings.json.tmpl
commit "harness drops the hook"
rm -rf "$BASE_DIR"
harness > /dev/null
assert "with the base lost, the template at the manifest commit still drops the removed hook" '[[ "$(hook_count stale-hook.sh)" == "0" && "$(hook_count work-guard.sh)" == "1" ]]'

harness --override-settings > /dev/null
assert "--override-settings replaces the file with the harness render" '[[ "$(jq -r ".model // \"none\"" "$S")" == "none" && "$(hook_count work-guard.sh)" == "0" && "$(jq -r .permissions.defaultMode "$S")" == "plan" ]]'

printf '{"model": "x",}\n' > "$S"
broken=$(harness)
assert "settings.json that is not strict JSON is left untouched" '[[ "$(cat "$S")" == "{\"model\": \"x\",}" ]] && grep -q "not strict JSON" <<<"$broken"'

harness > /dev/null 2>&1 || true
printf '{}\n' > "$S"
dry=$(harness --dry-run)
assert "dry-run writes neither settings nor base" '[[ "$(cat "$S")" == "{}" ]] && grep -q "would deploy: settings.json" <<<"$dry"'

HARNESS_MANIFEST="$H/manifest.json" HARNESS_BACKUP_DIR="$H/backups" HOME="$H" bash "$REPO/install.sh" uninstall > /dev/null 2>&1 || true
assert "uninstall removes the merge base" '[[ ! -e "$BASE_DIR" ]]'

echo ""
echo "Settings reconcile: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
