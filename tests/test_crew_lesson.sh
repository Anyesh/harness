#!/usr/bin/env bash
set -euo pipefail

unset CREW_LESSONS_MAX_BYTES CREW_LESSON_DUP_PCT CREW_LEAD_NOTES_MAX_BYTES

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CL="$REPO_ROOT/configs/claude-code/bin/crew-lesson"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '        out: %s\n' "${OUT//$'\n'/$'\n             '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'command rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
git init -q "$REPO"
CREW="$REPO/.claude/crew"
export CREW_MEMORY_DIR="$TMP_DIR/store"
export XDG_CONFIG_HOME="$CREW_MEMORY_DIR.xdg"
unset CREW_MEMORY_REMOTE
STORE=$CREW_MEMORY_DIR
MEM=$STORE/repos/repo
mkdir -p "$CREW"
BRIEF="$CREW/brief.md"
TODAY=$(date +%F)

OUT=
RC=0
cl() {
  RC=0
  OUT=$(cd "$REPO" && "$CL" "$@" 2>&1) || RC=$?
}
lessons() { awk '/^## Lessons$/ {f = 1; next} f && /^## / {f = 0} f && /^- /' "$BRIEF"; }
snap() { command cp "$BRIEF" "$TMP_DIR/before"; }
unchanged() { cmp -s "$BRIEF" "$TMP_DIR/before"; }

write_brief() {
  cat >"$BRIEF" <<'EOF'
# Brief

Run tests with uv.

## Lessons

- Settle a docker stack until its health checks pass before measuring anything on it (2026-11-05)
- Run each service's pytest separately because their conftest files collide (2026-11-02)

## After

Tail text.
EOF
}

echo "add"
write_brief
cl add "Pass --frozen to every uv sync in a worktree so the lockfile never changes"
assert "a new rule is added" '[[ $RC -eq 0 ]]'
assert "it lands as the last lesson with today's date" \
  '[[ $(lessons | tail -n 1) == "- Pass --frozen to every uv sync in a worktree so the lockfile never changes ($TODAY)" ]]'
assert "the next section and the text above stay" 'grep -qx "Tail text." "$BRIEF" && grep -qx "Run tests with uv." "$BRIEF" && [[ $(lessons | wc -l) -eq 3 ]]'
assert "the line goes before the next heading's blank line" \
  '[[ $(grep -n -A1 -- "--frozen" "$BRIEF" | tail -n 1) == *"-" ]]'

write_brief
cl add "- Keep screenshots out of git (2026-10-01)"
assert "a leading dash and a given date are kept once" '[[ $(lessons | tail -n 1) == "- Keep screenshots out of git (2026-10-01)" ]]'

echo "repeats"
write_brief
snap
cl add "Settle the docker stack until health checks pass before measuring anything"
assert "a rule that repeats a line is refused" '[[ $RC -eq 1 ]] && unchanged'
assert "the refusal names the line to merge into" 'grep -q "repeats line 7" <<<"$OUT" && grep -q "Settle a docker stack" <<<"$OUT"'
CREW_LESSON_DUP_PCT=95 cl add "Settle the docker stack until health checks pass before measuring"
assert "CREW_LESSON_DUP_PCT sets how close a repeat is" '[[ $RC -eq 0 ]]'

echo "similar"
write_brief
cl similar "measure the stack only after its health checks pass"
assert "similar lists the closest line with its number and score" '[[ $RC -eq 0 ]] && grep -qE "^7	[0-9]+%	- Settle a docker stack" <<<"$OUT"'
assert "similar leaves out unrelated lines" '! grep -q conftest <<<"$OUT"'
cl add "Name the worktree path in every report so the lead can find leftovers"
assert "add shows the nearest lines it was weighed against" '[[ $RC -eq 0 ]]'

echo "size limit"
write_brief
snap
CREW_LESSONS_MAX_BYTES=200 cl add "Name the worktree path in every report so the lead can find leftovers"
assert "a rule past the size limit is refused" '[[ $RC -eq 1 ]] && unchanged && grep -q "merge or retire" <<<"$OUT"'
cl size
assert "size prints bytes over the limit and passes" '[[ $RC -eq 0 && $OUT =~ ^[0-9]+/8192\ bytes$ ]]'
CREW_LESSONS_MAX_BYTES=50 cl size
assert "size fails when over the limit" '[[ $RC -eq 1 ]]'
echo "CREW_LESSONS_MAX_BYTES=60" >"$CREW/thresholds"
cl size
assert "the limit can come from the thresholds file" '[[ $RC -eq 1 && $OUT == */60\ bytes* ]]'
command rm -f "$CREW/thresholds"

echo "no lessons yet"
printf '# Brief\n\nRun tests with uv.\n' >"$BRIEF"
cl add "Keep screenshots out of git"
assert "add creates the Lessons heading at the end" \
  '[[ $RC -eq 0 && $(tail -n 3 "$BRIEF" | head -n 1) == "## Lessons" && $(lessons) == "- Keep screenshots out of git ($TODAY)" ]]'
command rm -f "$BRIEF"
cl add "Keep screenshots out of git"
assert "add creates brief.md when it is missing" '[[ $RC -eq 0 && $(lessons) == "- Keep screenshots out of git ($TODAY)" ]]'

echo "memory store"
mkdir -p "$MEM" "$STORE/rules"
command rm -f "$BRIEF"
cl add "Keep screenshots out of version control"
assert "with a store entry the worker lesson goes to the store's brief.md" '[[ $RC -eq 0 && ! -e $BRIEF ]] && grep -qx -- "- Keep screenshots out of version control ($TODAY)" "$MEM/brief.md"'
echo "CREW_LESSONS_MAX_BYTES=20" >"$MEM/thresholds"
cl size
assert "thresholds are read from the store entry" '[[ $RC -eq 1 && $OUT == */20\ bytes* ]]'
command rm -f "$MEM/thresholds"

echo "lead notes"
LEAD=$MEM/lead-notes.md
printf '# Lead notes\n\n- Restart the sweep after every ruling so it sees the board (2026-11-01)\n' >"$LEAD"
cl add --lead "Pass --frozen to every uv sync in a worktree so the lockfile never changes"
assert "--lead appends a dated line to lead-notes.md" '[[ $RC -eq 0 && $(tail -n 1 "$LEAD") == "- Pass --frozen to every uv sync in a worktree so the lockfile never changes ($TODAY)" && $(head -n 1 "$LEAD") == "# Lead notes" ]]'
command cp -f "$LEAD" "$TMP_DIR/lead-before"
cl add --lead "Restart the sweep after each ruling so that it sees the whole board"
assert "--lead refuses a repeat of a line anywhere in the file" '[[ $RC -eq 1 && $OUT == *"repeats line 3"* ]] && cmp -s "$LEAD" "$TMP_DIR/lead-before"'
cl similar --lead "restart the sweep after a ruling to see the board"
assert "similar --lead lists lead-notes lines" '[[ $RC -eq 0 && $OUT == *"Restart the sweep"* ]]'
CREW_LEAD_NOTES_MAX_BYTES=100 cl add --lead "Name the worktree path in every report so the lead can find leftovers"
assert "--lead refuses a line past CREW_LEAD_NOTES_MAX_BYTES" '[[ $RC -eq 1 && $OUT == *"merge or retire"* ]] && cmp -s "$LEAD" "$TMP_DIR/lead-before"'
cl size --lead
assert "size --lead counts the whole file against 12288" '[[ $RC -eq 0 && $OUT =~ ^[0-9]+/12288\ bytes$ ]]'
echo "CREW_LEAD_NOTES_MAX_BYTES=60" >"$MEM/thresholds"
cl size --lead
assert "the lead cap can come from the thresholds file" '[[ $RC -eq 1 && $OUT == */60\ bytes* ]]'
command rm -f "$MEM/thresholds"
printf 'no newline at end' >"$LEAD"
cl add --lead "Name the worktree path in every report so the lead can find leftovers"
assert "--lead starts a new line after a file with no trailing newline" '[[ $RC -eq 0 && $(head -n 1 "$LEAD") == "no newline at end" && $(wc -l <"$LEAD") -eq 2 ]]'
command rm -f "$LEAD"
cl add --lead "Name the worktree path in every report so the lead can find leftovers"
assert "--lead creates lead-notes.md when it is missing" '[[ $RC -eq 0 && -f $LEAD ]]'
assert "worker lessons are untouched by --lead" '[[ $(grep -c "^- " "$MEM/brief.md") -eq 1 ]]'

echo "all crews"
PROPOSED=$STORE/rules/proposed.md
cl add --all "Never run two migrations that claim the same alembic head in one batch"
assert "--all appends to rules/proposed.md tagged with the date and key" '[[ $RC -eq 0 && $(tail -n 1 "$PROPOSED") == "- Never run two migrations that claim the same alembic head in one batch ($TODAY, repo)" ]]'
command cp -f "$PROPOSED" "$TMP_DIR/prop-before"
cl add --all "Never run two migrations claiming the same alembic head in a batch"
assert "--all refuses a repeat" '[[ $RC -eq 1 && $OUT == *repeats* ]] && cmp -s "$PROPOSED" "$TMP_DIR/prop-before"'
cl add --all "Keep screenshots out of version control (2026-10-01, other)"
assert "--all keeps a tag the rule already carries" '[[ $RC -eq 0 && $(tail -n 1 "$PROPOSED") == "- Keep screenshots out of version control (2026-10-01, other)" ]]'
head -c 8200 /dev/zero | tr '\0' x >>"$PROPOSED"
printf '\n' >>"$PROPOSED"
cl add --all "Name the worktree path in every report so the lead can find leftovers"
assert "--all refuses a line past the 8192 cap" '[[ $RC -eq 1 && $OUT == *"merge or retire"* ]]'
cl size --all
assert "size --all reports against 8192 and fails when over" '[[ $RC -eq 1 && $OUT == */8192\ bytes* ]]'
command rm -rf "$STORE/rules"
cl add --all "Name the worktree path in every report so the lead can find leftovers"
assert "--all creates rules/proposed.md when the store has none" '[[ $RC -eq 0 && -f $PROPOSED ]]'
cl add --lead --all "x y z w"
assert "two targets together are a usage error" '[[ $RC -eq 2 ]]'
command rm -rf "$STORE"
cl add --all "Keep screenshots out of version control"
assert "--all with no store is refused" '[[ $RC -eq 1 && $OUT == *store* ]]'

echo "usage"
write_brief
snap
cl add $'two\nlines'
assert "a rule with a newline is refused" '[[ $RC -ne 0 ]] && unchanged'
cl add ""
assert "an empty rule is refused" '[[ $RC -ne 0 ]] && unchanged'
cl nope
assert "an unknown command is a usage error" '[[ $RC -eq 2 ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
