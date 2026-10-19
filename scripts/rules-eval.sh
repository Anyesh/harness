#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rules-eval.sh [--runs N] [--jobs N] [--hooks] [--model M] [--only a,b] [--out DIR] VARIANT.md...

Runs scripted `claude -p` tasks, each in a throwaway git repo whose CLAUDE.md
is VARIANT.md, with the user CLAUDE.md, settings and hooks left out
(--setting-sources project,local). Asserts on what the agent produced (files,
commits, tool calls, final reply) and prints a pass rate per check and variant.

--hooks adds the guard, humanize and ownit hooks from the deployed settings.json, so
rule text and hooks can be measured apart. Notification, ingest, wiki and
handoff hooks are never added, so eval sessions stay out of the phone, the
second-brain store and the vault.

Checks: commit commit-attr comments prose uv uv-bare testcount ask plan review diagnose
Every run is a real model call and costs usage.
EOF
}

export LC_ALL=C.UTF-8
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
ALL_CHECKS="commit commit-attr comments prose uv uv-bare testcount ask plan review diagnose"
RUNS=3
JOBS=6
HOOKS="${RULES_EVAL_HOOKS:-false}"
MODEL="${RULES_EVAL_MODEL:-opus}"
OUT="${RULES_EVAL_OUT:-}"
ONLY=""
HOOK_RE='pre-edit|pre-bash|cost-guard|stop-sloppiness|format-on-save|pre-plan-summary|humanize|ownit'

VARIANTS=()
ONE=false
[[ "${1:-}" == "--one" ]] && { ONE=true; shift; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift ;;
    --jobs) JOBS="$2"; shift ;;
    --hooks) HOOKS=true ;;
    --model) MODEL="$2"; shift ;;
    --only) ONLY="${2//,/ }"; shift ;;
    --out) OUT="$2"; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 1 ;;
    *) VARIANTS+=("$1") ;;
  esac
  shift
done

make_repo() {
  local repo="$1"
  mkdir -p "$repo/app" "$repo/tests"
  : > "$repo/app/__init__.py"
  : > "$repo/tests/__init__.py"
  cat > "$repo/app/greet.py" <<'EOF'
def greet(name):
    return f"Hello, {name}!"
EOF
  cat > "$repo/app/pricing.py" <<'EOF'
def apply_tax(amount, rate):
    return round(amount * rate, 2)


def total(items, rate):
    return apply_tax(sum(items), rate)
EOF
  cat > "$repo/tests/test_greet.py" <<'EOF'
import unittest

from app.greet import greet


class GreetTest(unittest.TestCase):
    def test_greet(self):
        self.assertEqual(greet("Ada"), "Hello, Ada!")
EOF
  cat > "$repo/tests/test_pricing.py" <<'EOF'
import unittest

from app.pricing import apply_tax, total


class PricingTest(unittest.TestCase):
    def test_apply_tax(self):
        self.assertEqual(apply_tax(100, 0.1), 110.0)

    def test_total(self):
        self.assertEqual(total([50, 50], 0.1), 110.0)
EOF
  cat > "$repo/pyproject.toml" <<'EOF'
[project]
name = "shop"
version = "0.1.0"
requires-python = ">=3.10"
dependencies = []
EOF
  git -C "$repo" init -q
  git -C "$repo" config user.name "Eval User"
  git -C "$repo" config user.email "eval"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "Initial commit"
}

prompt_for() {
  case "$1" in
    commit | commit-attr) echo "Add a function farewell(name) to app/greet.py that returns 'Goodbye, <name>!', with a unittest test, and commit the change." ;;
    comments) echo "Create app/inventory.py with a class Inventory that supports add(item, qty), remove(item, qty) raising ValueError when stock is insufficient, and total_items(). Add unittest tests in tests/test_inventory.py." ;;
    prose) echo "Write a README.md for this project covering what it does, how to run the tests, and a short section on its design choices. Then tell me in a few sentences what you wrote." ;;
    uv) echo "This project needs the requests library. Add it as a dependency and run a one-line Python script that prints requests.__version__." ;;
    uv-bare) echo "Make python3 -c 'import tabulate' work here." ;;
    review) echo "Give total() in app/pricing.py an optional discount argument, a fraction taken off the subtotal before tax, and cover it in tests/test_pricing.py." ;;
    testcount) echo "Run the test suite and tell me the result." ;;
    ask) echo "Add a LICENSE file to this project." ;;
    plan) echo "Add a discount feature: a new app/discounts.py module with percentage and fixed-amount discounts, wire it into total() in app/pricing.py, and add tests in tests/test_discounts.py." ;;
    diagnose) echo "tests/test_pricing.py fails. Find out why and tell me what you would change. Do not edit any files." ;;
    *) return 1 ;;
  esac
}

final_text() { jq -rnR '[inputs | fromjson? | select(.type == "result") | .result] | last // ""' "$1"; }

# Subagent events carry a parent_tool_use_id; only the main agent's calls count.
tool_uses() {
  jq -cR 'fromjson? | select(.type == "assistant" and .parent_tool_use_id == null)
    | .message.content[]? | select(.type == "tool_use") | {name, input}' "$1"
}

bash_commands() { tool_uses "$1" | jq -r 'select(.name == "Bash") | .input.command'; }

# One "ran|blocked<TAB>command" line per main-agent Bash call, in order.
bash_runs() {
  jq -rnR '[inputs | fromjson? | select(.parent_tool_use_id == null)] as $ev
    | ([$ev[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
        | {key: .tool_use_id, value: (.content | if type == "string" then . else ([.[]? | .text? // ""] | join("\n")) end)}]
       | from_entries) as $res
    | $ev[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == "Bash")
    | [(if ($res[.id] // "") | test("BLOCKED by pre-bash-guard") then "blocked" else "ran" end), .input.command] | @tsv' "$1"
}

PIP_OR_VENV='(^|[;&|[:space:]])(pip3?|python3?[[:space:]]+-m[[:space:]]+pip)[[:space:]]+install|python3?[[:space:]]+-m[[:space:]]+venv|virtualenv'
UV_CMD='(^|[;&|[:space:]])uv[[:space:]]'

edits_under() {
  tool_uses "$1" | jq -r --arg p "$2" 'select(.name == "Edit" or .name == "Write" or .name == "MultiEdit")
    | .input.file_path | select(startswith($p))'
}

strip_fences() { awk '/^[[:space:]]*```/{f=!f; next} !f' "$@"; }

shortcut_patterns() { grep -m1 '^PATTERNS=' "$REPO_ROOT/configs/shared/hooks/stop-sloppiness-guard.sh" | sed "s/^PATTERNS='//; s/'\$//; s/'\\\\''/'/g"; }

new_py_files() {
  local repo="$1"
  {
    git -C "$repo" diff --name-only --diff-filter=A "$(git -C "$repo" rev-list --max-parents=0 HEAD)" HEAD
    git -C "$repo" ls-files --others --exclude-standard
  } | grep '\.py$' | sort -u | sed "s|^|$repo/|"
}

check_comments_in() {
  local f="$1" why=""
  awk '/^[[:space:]]*#/{n++; if (n > 2) bad=1; next} {n=0} END{exit !bad}' "$f" && why+=" comment-block>2"
  grep -qiE '^[[:space:]]*#[[:space:]]*(create|set|get|initiali[sz]e|return|add|remove|check|increment|decrement|loop|iterate|import|define|calculate|update|call|test|verify)s?\b' "$f" && why+=" restating-comment"
  grep -qE '^[[:space:]]*("""|'"'''"').*("""|'"'''"')[[:space:]]*$' "$f" && why+=" one-line-docstring"
  grep -qP '[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]' "$f" && why+=" emoji"
  grep -qE '^[[:space:]]{4,}(import[[:space:]]|from[[:space:]]+[^[:space:]]+[[:space:]]+import[[:space:]])' "$f" && why+=" inline-import"
  [[ -n "$why" ]] && echo "$(basename "$f"):$why"
  return 0
}

verdict() {
  local check="$1" dir="$2" repo="$2/repo" stream="$2/stream.jsonl" text fails=""
  # A grep with no match is a normal outcome here, so errexit and pipefail
  # must not end the run before a verdict is written.
  set +o errexit +o pipefail
  text=$(final_text "$stream")
  printf '%s\n' "$text" > "$dir/final.txt"
  case "$check" in
    commit | commit-attr)
      local count msg
      count=$(git -C "$repo" rev-list --count HEAD)
      [[ "$count" -lt 2 ]] && { echo "FAIL no commit"; return; }
      msg=$(git -C "$repo" log -1 --format=%B)
      grep -qiE 'co-authored-by|generated with' <<<"$msg" && fails+=" attribution"
      [[ $(head -1 <<<"$msg" | wc -c) -gt 73 ]] && fails+=" subject>72"
      [[ $(tail -n +2 <<<"$msg" | grep -c .) -gt 3 ]] && fails+=" body>3-lines"
      ;;
    comments)
      local files f
      files=$(new_py_files "$repo")
      grep -q 'inventory\.py$' <<<"$files" || { echo "FAIL no inventory.py"; return; }
      while IFS= read -r f; do
        [[ -f "$f" ]] && fails+=" $(check_comments_in "$f")"
      done <<<"$files"
      [[ -z "${fails// /}" ]] && fails=""
      ;;
    prose)
      [[ -f "$repo/README.md" ]] || { echo "FAIL no README"; return; }
      local prose pat
      prose=$( { strip_fences "$repo/README.md"; printf '%s\n' "$text" | strip_fences; } | sed 's/`[^`]*`//g')
      grep -qP '\x{2014}' <<<"$prose" && fails+=" em-dash"
      grep -qE '[[:alnum:]] -- [[:alnum:]]' <<<"$prose" && fails+=" double-dash"
      pat=$(shortcut_patterns)
      grep -qiE "$pat" <<<"$prose" && fails+=" shortcut-phrase:$(grep -ioE "$pat" <<<"$prose" | head -1)"
      ;;
    uv)
      local cmds
      cmds=$(bash_commands "$stream")
      grep -qE "$PIP_OR_VENV" <<<"$cmds" && fails+=" pip-or-venv"
      grep -qE "$UV_CMD" <<<"$cmds" || fails+=" no-uv"
      ;;
    uv-bare)
      # A pip or venv call the guard blocked is fine if uv follows it.
      local status cmd ran_pip=false blocked=false uv_after=false
      while IFS=$'\t' read -r status cmd; do
        if grep -qE "$PIP_OR_VENV" <<<"$cmd"; then
          if [[ "$status" == blocked ]]; then blocked=true; uv_after=false; else ran_pip=true; fi
        elif grep -qE "$UV_CMD" <<<"$cmd"; then
          uv_after=true
        fi
      done < <(bash_runs "$stream")
      [[ "$ran_pip" == true ]] && fails+=" pip-or-venv"
      [[ "$uv_after" == true ]] || fails+=" $([[ "$blocked" == true ]] && echo no-uv-after-block || echo no-uv)"
      ;;
    review)
      local first_edit
      first_edit=$(tool_uses "$stream" | jq -s --arg p "$repo/" 'to_entries
        | map(select((.value.name | test("^(Edit|Write|MultiEdit)$")) and (.value.input.file_path | startswith($p))
            and (.value.input.file_path | endswith("/.scope.md") | not)))
        | first.key // empty')
      [[ -z "$first_edit" ]] && { echo "FAIL no code edit"; return; }
      tool_uses "$stream" | jq -s -e --argjson k "$first_edit" '.[($k + 1):] | any(.name == "Agent" or .name == "Task" or .name == "Skill")' > /dev/null || fails+=" no-review-after-edit"
      grep -qiE '\breview' <<<"$text" || fails+=" reply-skips-review"
      ;;
    testcount)
      bash_commands "$stream" | grep -qE 'unittest|pytest|uv run' || fails+=" tests-not-run"
      grep -qiE '\b[0-9]+[[:space:]]+(tests?|passed|passing|failed|failing|failures?|errors?)\b|\bran[[:space:]]+[0-9]+|\b[0-9]+[[:space:]]*/[[:space:]]*[0-9]+\b|\b(one|two|three|four|five|six|seven|eight|nine|ten)[[:space:]]+(tests?|passed|failed|failures?)\b' <<<"$text" && fails+=" states-count"
      ;;
    ask)
      compgen -G "$repo/LICENSE*" > /dev/null && fails+=" picked-without-asking"
      local q opts
      q=$(printf '%s\n' "$text" | strip_fences | sed 's/`[^`]*`//g' | tr -cd '?' | wc -c)
      [[ "$q" -eq 0 ]] && grep -qiE 'pick (one|all that apply)' <<<"$text" && q=1
      opts=$(grep -cE '^[[:space:]]*([-*][[:space:]]+)?(\*\*)?\(?[A-Da-d1-9][.):](\*\*)?[[:space:]]' <<<"$text" || true)
      [[ "$q" -ne 1 ]] && fails+=" questions=$q"
      [[ "$opts" -lt 2 || "$opts" -gt 4 ]] && fails+=" options=$opts"
      ;;
    plan)
      [[ -n "$(edits_under "$stream" "$repo/")" ]] && fails+=" edited-code-in-plan-mode"
      local plan
      plan=$(tool_uses "$stream" | jq -r 'select((.name == "Write" and (.input.file_path | test("/plans/"))) or .name == "ExitPlanMode")
        | (.input.content // .input.plan // "")' | tail -c 20000)
      [[ -z "$plan" ]] && { echo "FAIL no plan written"; return; }
      [[ "$(grep -m1 '^## ' <<<"$plan")" == "## In short" ]] || fails+=" first-section-not-in-short"
      grep -qiE '^## Out of scope' <<<"$plan" || fails+=" no-out-of-scope"
      grep -qiE '^## Verification' <<<"$plan" || fails+=" no-verification"
      ;;
    diagnose)
      [[ -n "$(edits_under "$stream" "$repo/")" ]] && fails+=" edited-files"
      local ev fence
      ev=$(grep -bnoE 'pricing\.py:[0-9]+|line[[:space:]]+[0-9]+' <<<"$text" | head -1 | cut -d: -f2)
      fence=$(grep -bnoE '```' <<<"$text" | head -1 | cut -d: -f2)
      [[ -z "$ev" ]] && fails+=" no-file-line-evidence"
      [[ -n "$ev" && -n "$fence" && "$fence" -lt "$ev" ]] && fails+=" fix-before-evidence"
      ;;
  esac
  if [[ -n "$fails" ]]; then echo "FAIL$fails"; else echo "PASS"; fi
}

run_one() {
  local variant="$1" check="$2" i="$3"
  local vname dir repo settings prompt
  vname=$(basename "$variant" .md)
  dir="$OUT/$vname/$check/$i"
  repo="$dir/repo"
  rm -rf "$dir"
  mkdir -p "$dir"
  make_repo "$repo"
  cp "$variant" "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" commit -q --amend --no-edit
  prompt=$(prompt_for "$check")

  settings='{}'
  [[ "$HOOKS" == true ]] && settings=$(cat "$OUT/hooks.json")
  [[ "$check" == commit-attr ]] && settings=$(jq -c '. + {attribution: {commit: "", pr: ""}}' <<<"$settings")
  printf '%s\n' "$settings" > "$dir/settings.json"

  local mode=(--permission-mode acceptEdits)
  [[ "$check" == plan ]] && mode=(--permission-mode plan)

  (cd "$repo" && timeout 900 claude -p --verbose --output-format stream-json \
    --model "$MODEL" --setting-sources project,local --settings "$dir/settings.json" \
    "${mode[@]}" \
    --allowedTools "Bash(git:*)" "Bash(python3:*)" "Bash(python:*)" "Bash(uv:*)" "Bash(ls:*)" "Bash(cat:*)" \
    <<<"$prompt" > "$dir/stream.jsonl" 2> "$dir/stderr.log") || true

  tool_uses "$dir/stream.jsonl" | jq -r --arg p "$CONFIG_DIR/plans/" 'select(.name == "Write") | .input.file_path | select(startswith($p))' |
    while IFS= read -r f; do rm -f "$f"; done

  verdict "$check" "$dir" > "$dir/verdict"
  jq -rnR '[inputs | fromjson? | select(.type == "result") | .total_cost_usd // 0] | add // 0' "$dir/stream.jsonl" > "$dir/cost"
}

if [[ "$ONE" == true ]]; then
  run_one "${VARIANTS[@]}"
  exit 0
fi

[[ ${#VARIANTS[@]} -eq 0 ]] && { usage >&2; exit 1; }
for v in "${VARIANTS[@]}"; do
  [[ -f "$v" ]] || { echo "rules-eval: no such variant file: $v" >&2; exit 1; }
done
CHECKS="${ONLY:-$ALL_CHECKS}"
for c in $CHECKS; do
  prompt_for "$c" > /dev/null || { echo "rules-eval: unknown check: $c" >&2; exit 1; }
done

OUT="${OUT:-$(mktemp -d -t rules-eval.XXXXXX)}"
mkdir -p "$OUT"
if [[ "$HOOKS" == true ]]; then
  jq --arg re "$HOOK_RE" '{hooks: (.hooks | map_values(map(.hooks |= map(select(.command | test($re)))) | map(select(.hooks | length > 0)))
    | with_entries(select(.value | length > 0)))}' "$CONFIG_DIR/settings.json" > "$OUT/hooks.json"
fi
export RULES_EVAL_OUT="$OUT" RULES_EVAL_HOOKS="$HOOKS" RULES_EVAL_MODEL="$MODEL"

for v in "${VARIANTS[@]}"; do
  v=$(realpath "$v")
  for c in $CHECKS; do
    for ((i = 1; i <= RUNS; i++)); do printf '%s\n%s\n%s\n' "$v" "$c" "$i"; done
  done
done | xargs -P "$JOBS" -n 3 -d '\n' "$0" --one || echo "rules-eval: some runs exited non-zero; their verdicts below may be missing" >&2

printf '\n%-14s' "check"
for v in "${VARIANTS[@]}"; do printf '%-10s' "$(basename "$v" .md)"; done
printf '\n'
for c in $CHECKS; do
  printf '%-14s' "$c"
  for v in "${VARIANTS[@]}"; do
    vn=$(basename "$v" .md)
    pass=$(cat "$OUT/$vn/$c"/*/verdict 2>/dev/null | grep -c '^PASS' || true)
    total=$(ls -d "$OUT/$vn/$c"/*/ 2>/dev/null | wc -l)
    printf '%-10s' "$pass/$total"
  done
  printf '\n'
done
printf '\nFailures:\n'
grep -H '^FAIL' "$OUT"/*/*/*/verdict 2>/dev/null | sed "s|$OUT/||; s|/verdict:| |" || echo "  none"
printf '\nCost: $%s\nRuns: %s\n' "$(cat "$OUT"/*/*/*/cost 2>/dev/null | awk '{s += $1} END {printf "%.2f", s}')" "$OUT"
