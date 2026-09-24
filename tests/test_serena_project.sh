#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

select_langs() {
    PYTHONPATH="$REPO_ROOT/lib" python3 -c '
import json, sys
from serena_languages import select_languages
spec = json.loads(sys.argv[1])
files = [set(m) for m in spec["files"]]
print(",".join(select_languages(files, spec["priorities"])))
' "$1"
}

echo ""
echo "=== select_languages ==="
echo ""

# 60 .ts files matched by typescript, vue and svelte (Serena's real overlap),
# 40 .py files, 2 .sh files: vue/svelte add nothing beyond typescript and
# bash is under the 5% floor.
mixed=$(python3 -c '
import json
files = [["typescript", "vue", "svelte"]] * 60 + [["python"]] * 40 + [["bash"]] * 2 + [[]] * 50
print(json.dumps({"files": files, "priorities": {"typescript": 2, "vue": 1, "svelte": 1, "python": 2, "bash": 2}}))
')
assert "superset matchers dropped, minor language dropped" '[[ "$(select_langs "$mixed")" == "typescript,python" ]]'

vue_repo=$(python3 -c '
import json
files = [["typescript", "vue", "svelte"]] * 50 + [["vue"]] * 30 + [["python"]] * 20
print(json.dumps({"files": files, "priorities": {"typescript": 2, "vue": 1, "svelte": 1, "python": 2}}))
')
assert "vue repo selects vue, which also covers the .ts files" '[[ "$(select_langs "$vue_repo")" == "vue,python" ]]'

tie=$(python3 -c '
import json
print(json.dumps({"files": [["typescript", "vue"]] * 10, "priorities": {"typescript": 2, "vue": 1}}))
')
assert "tie broken by priority" '[[ "$(select_langs "$tie")" == "typescript" ]]'

scattered=$(python3 -c '
import json
files = [[f"lang{i}"] for i in range(40)]
print(json.dumps({"files": files, "priorities": {f"lang{i}": 1 for i in range(40)}}))
')
assert "top language kept even when under the floor" '[[ "$(select_langs "$scattered")" == "lang0" ]]'

empty='{"files": [[], []], "priorities": {}}'
assert "no recognised files selects nothing" '[[ -z "$(select_langs "$empty")" ]]'

echo ""
echo "=== project.yml editing ==="
echo ""

langs_cli() {
    python3 "$REPO_ROOT/lib/serena_languages.py" "$@"
}

block_yml="$TMP_DIR/block.yml"
cat > "$block_yml" <<'YAML'
project_name: "wardrobe"
# The first language server is the default language
language_servers:
- typescript

# the encoding used by text files in the project
encoding: "utf-8"
YAML

assert "missing lists only absent languages" '[[ "$(langs_cli missing "$block_yml" typescript python)" == "python" ]]'
langs_cli add "$block_yml" python
assert "add appends after the existing item" '[[ "$(sed -n 3,5p "$block_yml")" == $'"'"'language_servers:\n- typescript\n- python'"'"' ]]'
assert "add keeps comments and other keys" 'grep -qx "# the encoding used by text files in the project" "$block_yml" && grep -qx "encoding: \"utf-8\"" "$block_yml"'
before=$(cat "$block_yml")
langs_cli add "$block_yml" python typescript
assert "add is idempotent" '[[ "$(cat "$block_yml")" == "$before" ]]'

inline_yml="$TMP_DIR/inline.yml"
printf 'project_name: "x"\nlanguage_servers: []\nencoding: "utf-8"\n' > "$inline_yml"
langs_cli add "$inline_yml" typescript python
assert "inline empty list becomes a block list" '[[ "$(cat "$inline_yml")" == $'"'"'project_name: "x"\nlanguage_servers:\n- typescript\n- python\nencoding: "utf-8"'"'"' ]]'

quoted_yml="$TMP_DIR/quoted.yml"
printf 'language_servers:\n  - "python"\nencoding: "utf-8"\n' > "$quoted_yml"
assert "quoted, indented items are recognised" '[[ -z "$(langs_cli missing "$quoted_yml" python)" ]]'
langs_cli add "$quoted_yml" typescript
assert "new items reuse the existing indentation" '[[ "$(sed -n 3p "$quoted_yml")" == "  - typescript" ]]'

echo ""
echo "=== install.sh serena-project ==="
echo ""

# Stand-ins for the Serena internals serena_detect_languages.py imports, so
# the detection path runs without Serena installed. Matchers mirror the real
# overlap: vue claims .ts files too.
FAKE_SERENA="$TMP_DIR/fake-serena"
mkdir -p "$FAKE_SERENA/serena/config" "$FAKE_SERENA/serena/util" "$FAKE_SERENA/solidlsp"
touch "$FAKE_SERENA/serena/__init__.py" "$FAKE_SERENA/serena/config/__init__.py" \
      "$FAKE_SERENA/serena/util/__init__.py" "$FAKE_SERENA/solidlsp/__init__.py"
cat > "$FAKE_SERENA/serena/config/serena_config.py" <<'PY'
class SerenaConfig:
    @classmethod
    def from_config_file(cls):
        return cls()

    def get_ls_priority(self, ls_id):
        return ls_id.get_priority()
PY
cat > "$FAKE_SERENA/serena/util/file_system.py" <<'PY'
import os


def find_all_non_ignored_files(repo_root):
    return [os.path.join(d, f) for d, _, fs in os.walk(repo_root) if ".serena" not in d for f in fs]
PY
cat > "$FAKE_SERENA/solidlsp/ls_config.py" <<'PY'
from enum import Enum

EXTENSIONS = {"typescript": (".ts",), "vue": (".ts", ".vue"), "python": (".py",), "bash": (".sh",)}
PRIORITIES = {"typescript": 2, "vue": 1, "python": 2, "bash": 2}


class Matcher:
    def __init__(self, exts):
        self.exts = exts

    def is_relevant_filename(self, name):
        return name.endswith(self.exts)


class LanguageServerId(Enum):
    TYPESCRIPT = "typescript"
    VUE = "vue"
    PYTHON = "python"
    BASH = "bash"

    def get_source_fn_matcher(self):
        return Matcher(EXTENSIONS[self.value])

    def get_priority(self):
        return PRIORITIES[self.value]
PY

MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"
SERENA_CALLS="$TMP_DIR/serena-calls"
cat > "$MOCK_BIN/serena" <<PY
#!/usr/bin/env python3
import sys
with open("$SERENA_CALLS", "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
PY
chmod +x "$MOCK_BIN/serena"

make_repo() {
    local repo="$1"
    mkdir -p "$repo/frontend" "$repo/backend" "$repo/scripts"
    for i in $(seq 1 12); do touch "$repo/frontend/f$i.ts"; done
    for i in $(seq 1 8); do touch "$repo/backend/b$i.py"; done
    touch "$repo/scripts/deploy.sh"
}

run_serena_project() {
    HOME="$TMP_DIR/home" \
    HARNESS_MANIFEST="$TMP_DIR/manifest.json" \
    HARNESS_BACKUP_DIR="$TMP_DIR/backups" \
    PYTHONPATH="$FAKE_SERENA" \
    PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_ROOT/install.sh" serena-project "$@" 2>&1
}
mkdir -p "$TMP_DIR/home"

fresh="$TMP_DIR/fresh"
make_repo "$fresh"
: > "$SERENA_CALLS"
out=$(run_serena_project "$fresh") || true
assert "fresh repo: project created with every detected language" 'grep -qxF "project create $fresh --language typescript --language python" "$SERENA_CALLS"'
assert "fresh repo: mcp.json still written" 'grep -q "start-mcp-server" "$fresh/.mcp.json"'

existing="$TMP_DIR/existing"
make_repo "$existing"
mkdir -p "$existing/.serena"
printf 'project_name: "existing"\nlanguage_servers:\n- typescript\n\nencoding: "utf-8"\n' > "$existing/.serena/project.yml"
: > "$SERENA_CALLS"
out=$(run_serena_project "$existing") || true
assert "existing yml: missing language appended" '[[ "$(sed -n 2,4p "$existing/.serena/project.yml")" == $'"'"'language_servers:\n- typescript\n- python'"'"' ]]'
assert "existing yml: serena project create not called" '! grep -q "project create" "$SERENA_CALLS"'
assert "existing yml: backup taken" '[[ -n "$(find "$TMP_DIR/backups" -name project.yml 2>/dev/null)" ]]'
out=$(run_serena_project "$existing") || true
assert "existing yml: rerun reports nothing to add" 'echo "$out" | grep -q "already configured"'

dry="$TMP_DIR/dry"
make_repo "$dry"
mkdir -p "$dry/.serena"
printf 'language_servers:\n- typescript\n' > "$dry/.serena/project.yml"
before=$(cat "$dry/.serena/project.yml")
: > "$SERENA_CALLS"
out=$(run_serena_project --dry-run "$dry") || true
assert "dry-run: yml unchanged" '[[ "$(cat "$dry/.serena/project.yml")" == "$before" ]]'
assert "dry-run: says what it would add" 'echo "$out" | grep -q "\[dry-run\] would add serena languages: python"'
fresh_dry="$TMP_DIR/fresh-dry"
make_repo "$fresh_dry"
out=$(run_serena_project --dry-run "$fresh_dry") || true
assert "dry-run: fresh repo creates nothing" '[[ ! -e "$fresh_dry/.serena" ]] && ! grep -q "project create" "$SERENA_CALLS"'

broken="$TMP_DIR/broken"
make_repo "$broken"
: > "$SERENA_CALLS"
out=$(PYTHONPATH="$TMP_DIR/nowhere" HOME="$TMP_DIR/home" HARNESS_MANIFEST="$TMP_DIR/manifest.json" \
    HARNESS_BACKUP_DIR="$TMP_DIR/backups" PATH="$MOCK_BIN:$PATH" \
    bash "$REPO_ROOT/install.sh" serena-project "$broken" 2>&1) || true
assert "detection failure: falls back to serena's own inference" 'grep -qxF "project create $broken" "$SERENA_CALLS"'
assert "detection failure: warns" 'echo "$out" | grep -q "language detection failed"'

no_serena="$TMP_DIR/no-serena"
make_repo "$no_serena"
no_serena_path=""
IFS=: read -r -a path_dirs <<< "$PATH"
for dir in "${path_dirs[@]}"; do
    [[ -x "$dir/serena" ]] && continue
    no_serena_path="${no_serena_path:+$no_serena_path:}$dir"
done
out=$(HOME="$TMP_DIR/home" HARNESS_MANIFEST="$TMP_DIR/manifest.json" HARNESS_BACKUP_DIR="$TMP_DIR/backups" \
    PATH="$no_serena_path" bash "$REPO_ROOT/install.sh" serena-project "$no_serena" 2>&1) || true
assert "no serena: mcp.json still written" 'grep -q "start-mcp-server" "$no_serena/.mcp.json"'
assert "no serena: language step skipped with a warning" 'echo "$out" | grep -q "serena not on PATH"'

echo ""
echo "Serena project: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
