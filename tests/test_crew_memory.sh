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
export CREW_MEMORY_DIR="$TMP_DIR/store"
export XDG_CONFIG_HOME="$CREW_MEMORY_DIR.xdg"
unset CREW_MEMORY_REMOTE

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$BIN/crew-lib.sh"

new_repo() {
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
  [[ -z ${2:-} ]] || git -C "$1" remote add origin "$2"
}

mem() { (cd "$1" && "$BIN/crew-memory" "${@:2}"); }

echo "repo key"
new_repo "$TMP_DIR/a/Wardrobe" git@github.com:Me/Wardrobe.git
assert "origin over ssh normalizes to host/path" '[[ $(crew_origin_norm "$TMP_DIR/a/Wardrobe") == github.com/me/wardrobe ]]'
new_repo "$TMP_DIR/https" https://github.com/me/wardrobe/
assert "an https origin normalizes the same way" '[[ $(crew_origin_norm "$TMP_DIR/https") == github.com/me/wardrobe ]]'
new_repo "$TMP_DIR/none"
assert "no origin normalizes to none" '[[ $(crew_origin_norm "$TMP_DIR/none") == none ]]'
assert "with no store entry the key is the lowercase basename" '[[ $(crew_mem_key "$TMP_DIR/a/Wardrobe") == wardrobe ]]'
assert "crew_mem falls back to the crew dir before ensure" '[[ $(crew_mem "$TMP_DIR/a/Wardrobe") == "$TMP_DIR/a/Wardrobe/.claude/crew" ]]'

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
out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "ensure without a remote inits a local store" '[[ -d $CREW_MEMORY_DIR/.git && -f $CREW_MEMORY_DIR/rules/proposed.md && -f $CREW_MEMORY_DIR/.gitattributes ]]'
assert "an assigned row keeps ensure from moving anything" '[[ $out == *"MEMORY pending"* && -f $crew/check && ! -d $CREW_MEMORY_DIR/repos/wardrobe ]]'

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
store_repo="$CREW_MEMORY_DIR/repos/wardrobe"
assert "with nothing live ensure moves the persistent files" '[[ -x $store_repo/check && -x $store_repo/preflight.d/10-heads && -f $store_repo/brief.md && $(cat "$store_repo/heavy-slots") == 1 ]]'
assert "the crew dir keeps none of them" '[[ ! -e $crew/check && ! -e $crew/preflight.d && ! -e $crew/brief.md && ! -e $crew/heavy-slots && ! -e $crew/lead-notes.md ]]'
assert "the crew dir keeps run state" '[[ -f $crew/board.tsv && -d $crew/items/1 ]]'
assert "the origin is recorded" '[[ $(cat "$store_repo/origin") == github.com/me/wardrobe ]]'
assert "the handover section moves to the crew dir" '[[ $(cat "$crew/handover.md") == *"next: do x"* && $(cat "$store_repo/lead-notes.md") != *Handover* && $(cat "$store_repo/lead-notes.md") == *"- rule"* ]]'
assert "the move is committed" '[[ -z $(git -C "$CREW_MEMORY_DIR" status --porcelain) && $(git -C "$CREW_MEMORY_DIR" log -1 --format=%s) == wardrobe:* ]]'
assert "crew_mem now resolves to the store" '[[ $(crew_mem "$TMP_DIR/a/Wardrobe") == "$store_repo" ]]'
assert "crew_mem resolves from a linked worktree" 'git -C "$TMP_DIR/a/Wardrobe" worktree add -q -b w/x "$TMP_DIR/wt" && [[ $(crew_mem "$TMP_DIR/wt") == "$store_repo" ]]'
out=$(mem "$TMP_DIR/a/Wardrobe" ensure)
assert "a second ensure is a no-op" '[[ $out != *pending* && -x $store_repo/check ]]'

echo "key across clones"
new_repo "$TMP_DIR/b/wardrobe-copy" https://github.com/Me/Wardrobe.git
assert "another clone of the same origin finds the entry" '[[ $(crew_mem_key "$TMP_DIR/b/wardrobe-copy") == wardrobe ]]'
new_repo "$TMP_DIR/c/wardrobe" git@github.com:other/wardrobe.git
expected="wardrobe-$(printf %s github.com/other/wardrobe | sha1sum | cut -c1-4)"
assert "a different origin with a taken basename gets a hash suffix" '[[ $(crew_mem_key "$TMP_DIR/c/wardrobe") == "$expected" ]]'
assert "a repo with no origin keys on its basename" '[[ $(crew_mem_key "$TMP_DIR/none") == none ]]'
mem "$TMP_DIR/none" ensure >/dev/null
assert "a repo with no origin records origin none" '[[ $(cat "$CREW_MEMORY_DIR/repos/none/origin") == none ]]'

echo "stray"
printf '#!/bin/sh\n' >"$crew/check"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status names a persistent file left in the crew dir" '[[ $out == *"MEMORY stray $crew/check"* ]]'
command rm -f "$crew/check"

echo "sync"
out=$(mem "$TMP_DIR/a/Wardrobe" sync "first")
assert "sync with no remote commits and says so" '[[ $out == *"MEMORY no-remote"* ]]'
git init -q --bare -b main "$TMP_DIR/remote.git"
git -C "$CREW_MEMORY_DIR" remote add origin "$TMP_DIR/remote.git"
echo "- lesson" >>"$store_repo/brief.md"
out=$(mem "$TMP_DIR/a/Wardrobe" sync "add lesson")
assert "sync pushes to an empty remote" '[[ $out == "MEMORY ok "* && $(git -C "$TMP_DIR/remote.git" rev-parse main) == $(git -C "$CREW_MEMORY_DIR" rev-parse HEAD) ]]'
assert "the commit message carries the key" '[[ $(git -C "$CREW_MEMORY_DIR" log -1 --format=%s) == "wardrobe: add lesson" ]]'

git clone -q "$TMP_DIR/remote.git" "$TMP_DIR/store2"
echo "- rule from machine 2 (2026-11-20, other)" >>"$TMP_DIR/store2/rules/proposed.md"
git -C "$TMP_DIR/store2" commit -qam "other: rule"
git -C "$TMP_DIR/store2" push -q origin main
echo "- rule from machine 1 (2026-11-20, wardrobe)" >>"$CREW_MEMORY_DIR/rules/proposed.md"
out=$(mem "$TMP_DIR/a/Wardrobe" sync "rule")
assert "two machines appending to proposed.md merge without a conflict" '[[ $out == "MEMORY ok "* && $(grep -c "^- rule from" "$CREW_MEMORY_DIR/rules/proposed.md") == 2 ]]'

git -C "$TMP_DIR/store2" pull -q --rebase
echo "x2" >"$TMP_DIR/store2/repos/wardrobe/heavy-slots"
git -C "$TMP_DIR/store2" commit -qam "other: slots"
git -C "$TMP_DIR/store2" push -q origin main
echo "x1" >"$store_repo/heavy-slots"
out=$(mem "$TMP_DIR/a/Wardrobe" sync "slots") || true
assert "a conflicting edit is reported and the rebase aborted" '[[ $out == *"MEMORY conflict repos/wardrobe/heavy-slots"* && ! -d $CREW_MEMORY_DIR/.git/rebase-merge && $(cat "$store_repo/heavy-slots") == x1 ]]'
assert "after a conflict the local commit counts as unpushed" '[[ $out == *"MEMORY unpushed 1"* ]]'
git -C "$CREW_MEMORY_DIR" reset -q --hard origin/main

git -C "$CREW_MEMORY_DIR" remote set-url origin "$TMP_DIR/gone.git"
echo "- more" >>"$store_repo/brief.md"
out=$(mem "$TMP_DIR/a/Wardrobe" sync "more") || true
assert "a failed push says so" '[[ $out == *"MEMORY push-failed"* ]]'
assert "a failed push leaves the unpushed count" '[[ $out == *"MEMORY unpushed 1"* ]]'
git -C "$CREW_MEMORY_DIR" remote set-url origin "$TMP_DIR/remote.git"

echo "caps"
head -c 13000 /dev/zero | tr '\0' x >"$store_repo/lead-notes.md"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status reports a file over its cap" '[[ $out == *"MEMORY over repos/wardrobe/lead-notes.md 13000/12288"* ]]'
{
  printf '# brief\n## Lessons\n'
  head -c 9000 /dev/zero | tr '\0' y
  printf '\n## After\n'
} >"$store_repo/brief.md"
out=$(mem "$TMP_DIR/a/Wardrobe" status)
assert "status reports the Lessons section over its cap" '[[ $out == *"MEMORY over repos/wardrobe/brief.md#Lessons"* ]]'

echo "lock"
exec {held}>"$CREW_MEMORY_DIR/.sync.lock"
flock "$held"
out=$(cd "$TMP_DIR/a/Wardrobe" && CREW_MEMORY_LOCK_WAIT=1 "$BIN/crew-memory" sync "locked" 2>&1) && rc=0 || rc=$?
assert "sync waits for the sync lock and gives up after the wait" '[[ $rc != 0 && $out == *"MEMORY locked"* ]]'
exec {held}>&-
assert "the lock file is not committed" '! git -C "$CREW_MEMORY_DIR" ls-files --error-unmatch .sync.lock >/dev/null 2>&1'
assert "a .tmp file is ignored" 'touch "$store_repo/.tmp-check" && [[ -z $(git -C "$CREW_MEMORY_DIR" status --porcelain --untracked-files=all -- "repos/wardrobe/.tmp-check") ]]'

echo "leakguard"
assert "a store made without a secrets-only ruleset sets no leakguard config" '[[ -z $(git -C "$CREW_MEMORY_DIR" config --get leakguard.config) ]]'
mkdir -p "$HOME/.config/leakguard"
printf '[extend]\nuseDefault = true\n' >"$HOME/.config/leakguard/secrets-only.toml"
mem "$TMP_DIR/a/Wardrobe" status >/dev/null
mem "$TMP_DIR/a/Wardrobe" sync "lg" >/dev/null || true
assert "with the secrets-only ruleset installed the store scans for secrets only" '[[ $(git -C "$CREW_MEMORY_DIR" config --get leakguard.config) == "$HOME/.config/leakguard/secrets-only.toml" ]]'

echo "remote from the env file"
mkdir -p "$XDG_CONFIG_HOME/harness"
echo "CREW_MEMORY_REMOTE=$TMP_DIR/remote.git" >"$XDG_CONFIG_HOME/harness/crew-memory.env"
out=$(cd "$TMP_DIR/a/Wardrobe" && CREW_MEMORY_DIR="$TMP_DIR/store3" "$BIN/crew-memory" ensure)
assert "ensure clones the store from the remote in the env file" '[[ -f $TMP_DIR/store3/repos/wardrobe/origin && $(git -C "$TMP_DIR/store3" rev-parse HEAD) == $(git -C "$TMP_DIR/remote.git" rev-parse main) ]]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
