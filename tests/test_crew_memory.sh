#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_ROOT/configs/claude-code/bin"

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
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
TMP_DIR=$(cd "$TMP_DIR" && pwd -P)
trap 'command rm -rf "$TMP_DIR"' EXIT

export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export WIKI_VAULT="$TMP_DIR/vault"
unset HARNESS_WORK
mkdir -p "$WIKI_VAULT"

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$BIN/crew-lib.sh"

new_repo() {
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
}

mem() { (cd "$1" && "$BIN/crew-memory" "${@:2}"); }

echo "location"
new_repo "$TMP_DIR/a/Wardrobe"
wiki="$WIKI_VAULT/wiki/projects/wardrobe"
root="$wiki/crew"
assert "the key is the wiki project slug of the main checkout" '[[ $(crew_mem_key "$TMP_DIR/a/Wardrobe") == wardrobe ]]'
assert "the memory root is the crew folder of the project's wiki folder" '[[ $(crew_mem_root "$TMP_DIR/a/Wardrobe") == "$root" ]]'
assert "crew_mem falls back to the crew dir before ensure" '[[ $(crew_mem "$TMP_DIR/a/Wardrobe") == "$TMP_DIR/a/Wardrobe/.claude/crew" ]]'
assert "the proposals dir is the harness project's crew folder" '[[ $(crew_proposals_dir) == "$WIKI_VAULT/wiki/projects/harness/crew" ]]'
assert "HARNESS_WORK maps the vault to the work vault" '[[ $(HARNESS_WORK=1 crew_mem_root "$TMP_DIR/a/Wardrobe") == "$WIKI_VAULT/Work/agent-wiki/wiki/projects/wardrobe/crew" ]]'

echo "no vault"
out=$(cd "$TMP_DIR/a/Wardrobe" && WIKI_VAULT= "$BIN/crew-memory" ensure)
assert "ensure without a vault says so and exits 0" '[[ $out == "MEMORY no-vault" ]]'
out=$(cd "$TMP_DIR/a/Wardrobe" && WIKI_VAULT= "$BIN/crew-memory" status)
assert "status without a vault says so" '[[ $out == "MEMORY no-vault" ]]'

echo "ensure"
crew="$TMP_DIR/a/Wardrobe/.claude/crew"
mkdir -p "$crew/preflight.d" "$crew/items/1"
printf '# brief\n## Lessons\n- one\n' >"$crew/brief.md"
printf '# lead\n- rule\n## Handover\nnext: do x\n' >"$crew/lead-notes.md"
printf '#!/bin/sh\nexit 0\n' >"$crew/check"
printf '#!/bin/sh\nexit 0\n' >"$crew/preflight.d/10-heads"
chmod +x "$crew/check" "$crew/preflight.d/10-heads"
echo 1 >"$crew/heavy-slots"
printf '1\tassigned\tw-1\tw/1\tmain\t1\tx\t\n' >"$crew/board.tsv"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status before the move says not moved" '[[ $out == "MEMORY repo $root not moved"* ]]'
out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "an assigned row keeps ensure from moving anything" '[[ $out == *"MEMORY pending"* && -f $crew/check && ! -d $root ]]'

printf '1\tdone\tw-1\tw/1\tmain\t1\tx\t\n' >"$crew/board.tsv"
sleep 30 &
live=$!
printf 'pid %s\nstart %s\ntip abc\n' "$live" "$(crew_pid_start "$live")" >"$crew/items/1/merging"
out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "a live merge marker keeps ensure from moving anything" '[[ $out == *"MEMORY pending"* && -f $crew/check ]]'
command rm -f "$crew/items/1/merging"

mkdir -p "$crew/live"
printf '%s %s\n' "$live" "$(crew_pid_start "$live")" >"$crew/live/sweep.$live"
out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "a live sweep file keeps ensure from moving anything" '[[ $out == *"MEMORY pending"* && -f $crew/check ]]'
assert "the caller's own live file does not count" '! crew_mem_busy "$crew" "$crew/live/sweep.$live" >/dev/null'
kill "$live"
wait "$live" 2>/dev/null || true
assert "a dead sweep file does not count as live" '! crew_mem_busy "$crew" >/dev/null'

out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "with nothing live ensure moves the persistent files" '[[ -x $root/check && -x $root/preflight.d/10-heads && -f $root/brief.md && $(cat "$root/heavy-slots") == 1 ]]'
assert "the crew dir keeps none of them" '[[ ! -e $crew/check && ! -e $crew/preflight.d && ! -e $crew/brief.md && ! -e $crew/heavy-slots && ! -e $crew/lead-notes.md ]]'
assert "the crew dir keeps run state" '[[ -f $crew/board.tsv && -d $crew/items/1 ]]'
assert "the handover section moves to the crew dir" '[[ $(cat "$crew/handover.md") == *"next: do x"* && $(cat "$root/lead-notes.md") != *Handover* && $(cat "$root/lead-notes.md") == *"- rule"* ]]'
assert "no staging dir is left in the wiki folder" '! compgen -G "$wiki/.tmp-crew.*" >/dev/null'
assert "the crew folder gets an index" '[[ -f $root/index.md ]]'
assert "the project index links the crew folder, created with a title" '[[ $(head -n 1 "$wiki/index.md") == "# wardrobe" && $(grep -c "(crew/index.md)" "$wiki/index.md") == 1 ]]'
assert "crew_mem now resolves to the wiki crew dir" '[[ $(crew_mem "$TMP_DIR/a/Wardrobe") == "$root" ]]'
assert "crew_mem resolves from a linked worktree" 'git -C "$TMP_DIR/a/Wardrobe" worktree add -q -b w/x "$TMP_DIR/wt" && [[ $(crew_mem "$TMP_DIR/wt") == "$root" ]]'
out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "a second ensure is a no-op" '[[ -z $out && -x $root/check && $(grep -c "(crew/index.md)" "$wiki/index.md") == 1 ]]'

echo "index"
new_repo "$TMP_DIR/b/Other"
mkdir -p "$WIKI_VAULT/wiki/projects/other"
printf '# other\n\n- [Devlog](devlog.md): dated entries\n' >"$WIKI_VAULT/wiki/projects/other/index.md"
mem "$TMP_DIR/b/Other" ensure >/dev/null
assert "an existing project index keeps its lines and gains the crew link" '[[ $(grep -c "devlog.md" "$WIKI_VAULT/wiki/projects/other/index.md") == 1 && $(grep -c "(crew/index.md)" "$WIKI_VAULT/wiki/projects/other/index.md") == 1 ]]'
assert "a repo with nothing to move still gets a crew folder" '[[ -d $WIKI_VAULT/wiki/projects/other/crew ]]'

echo "status"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status names the moved root" '[[ $out == "MEMORY repo $root" ]]'
printf '#!/bin/sh\n' >"$crew/check"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status names a persistent file left in the crew dir" '[[ $out == *"MEMORY stray $crew/check"* ]]'
command rm -f "$crew/check"

echo "caps"
head -c 13000 /dev/zero | tr '\0' x >"$root/lead-notes.md"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "lead notes have no cap" '[[ $out != *"MEMORY over"* ]]'
{
  printf '# brief\n## Lessons\n'
  head -c 9000 /dev/zero | tr '\0' y
  printf '\n## After\n'
} >"$root/brief.md"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status reports the Lessons section over its cap" '[[ $out == *"MEMORY over crew/brief.md#Lessons 9001/8192"* ]]'
echo "CREW_LESSONS_MAX_BYTES=20000" >"$root/thresholds"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "the cap follows the thresholds file" '[[ $out != *"MEMORY over"* ]]'

echo "removed commands"
assert "sync is no longer a command" '! mem "$TMP_DIR/a/Wardrobe" sync >/dev/null 2>&1'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
