#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_ROOT/configs/claude-code/bin"
ARCHIVE="$BIN/crew-archive"

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

export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export WIKI_VAULT="$TMP_DIR/vault"
unset HARNESS_WORK

OUT=
RC=0
archive() {
  RC=0
  OUT=$(cd "$REPO" && "$ARCHIVE" "$@" 2>&1) || RC=$?
}

new_repo() {
  REPO=$TMP_DIR/$1
  git init -q -b main "$REPO"
  git -C "$REPO" commit -q --allow-empty -m init
  CREW=$REPO/.claude/crew
  mkdir -p "$CREW/items/1" "$CREW/items/2"
}

fill_run() {
  printf '1\tdone\tw-1\tw/1\tmain\t1\tx\t\n2\tdone\tw-2\tw/2\tmain\t1\ty\t\n3\tblocked\tw-3\tw/3\tmain\t1\tz\t\n' >"$CREW/board.tsv"
  printf '# Run outcome: both slices landed\n\nDetails.\n' >"$CREW/summary.md"
  printf 'ruling 1\n' >"$CREW/rulings.md"
  printf 'reflection\n' >"$CREW/reflections.md"
  printf 'plan\n' >"$CREW/plan.md"
  printf 'next: x\n' >"$CREW/handover.md"
  printf 'seen\n' >"$CREW/.sweep-seen"
  printf '2\n' >"$CREW/heavy-priority"
  for f in spec report notes review handoff; do printf '%s 1\n' "$f" >"$CREW/items/1/$f.md"; done
  printf 'log\n' >"$CREW/items/1/build.log"
  printf 'spec 2\n' >"$CREW/items/2/spec.md"
  head -c 300000 /dev/zero | tr '\0' x >"$CREW/items/2/report.md"
}

echo "a repo not yet in the wiki"
new_repo alpha
fill_run
printf '# brief\n## Lessons\n' >"$CREW/brief.md"
printf '#!/bin/sh\n' >"$CREW/check"
chmod +x "$CREW/check"
archive
STORE_REPO=$WIKI_VAULT/wiki/projects/alpha/crew
RUN=$(find "$CREW" -maxdepth 1 -type d -name 'done-*' | head -n 1)
ID=${RUN##*/done-}
assert "it exits 0 and creates a done dir named by the date and time" '[[ $RC -eq 0 && $ID =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$ ]]'
assert "the run files move into the done dir" '[[ -f $RUN/board.tsv && -f $RUN/rulings.md && -f $RUN/reflections.md && -f $RUN/plan.md && -f $RUN/summary.md && -f $RUN/handover.md && -f $RUN/.sweep-seen && -f $RUN/heavy-priority && -f $RUN/items/1/build.log ]]'
assert "the crew dir no longer holds them" '[[ ! -e $CREW/board.tsv && ! -e $CREW/items && ! -e $CREW/rulings.md && ! -e $CREW/summary.md && ! -e $CREW/handover.md && ! -e $CREW/.sweep-seen && ! -e $CREW/heavy-priority ]]'
assert "the first archive ensured the wiki crew folder" '[[ -d $STORE_REPO && -f $STORE_REPO/brief.md && -x $STORE_REPO/check && ! -e $CREW/brief.md ]]'
RUNS=$STORE_REPO/runs/$ID
assert "the durable text is copied into runs/<id>" '[[ -f $RUNS/summary.md && -f $RUNS/rulings.md && -f $RUNS/reflections.md && -f $RUNS/plan.md && -f $RUNS/board.tsv ]]'
assert "item files are not copied" '[[ ! -e $RUNS/items ]] && [[ -f $RUN/items/1/report.md ]]'
assert "handover.md stays out of the store copy" '[[ ! -e $RUNS/handover.md ]]'
assert "index.md gets one line: id, done/total, summary's first line" '[[ $(tail -n 1 "$STORE_REPO/index.md") == "$ID 2/3 items Run outcome: both slices landed" && $(grep -c "^$ID " "$STORE_REPO/index.md") -eq 1 ]]'
assert "no sync output is printed" '[[ $OUT != *MEMORY* ]]'

archive
assert "a rerun with nothing to archive succeeds and adds nothing" '[[ $RC -eq 0 && $(grep -c "^$ID " "$STORE_REPO/index.md") -eq 1 && $(find "$CREW" -maxdepth 1 -name "done-*" | wc -l) -eq 1 ]]'

echo "import"
IMP=$CREW/done-2026-11-01-101010
mkdir -p "$IMP/items/7"
printf '1\tdone\tw-7\tw/7\tmain\t1\tx\t\n' >"$IMP/board.tsv"
printf 'Imported run\n' >"$IMP/summary.md"
printf 'spec 7\n' >"$IMP/items/7/spec.md"
archive --import "$IMP"
assert "--import copies the run into runs/<id> and indexes it" '[[ $RC -eq 0 && -f $STORE_REPO/runs/2026-11-01-101010/summary.md && ! -e $STORE_REPO/runs/2026-11-01-101010/items && $(grep -c "^2026-11-01-101010 1/1 items Imported run$" "$STORE_REPO/index.md") -eq 1 ]]'
assert "--import leaves the done dir as it was" '[[ -f $IMP/board.tsv && -f $IMP/items/7/spec.md ]]'
archive --import "$IMP"
assert "importing twice does not duplicate the index line" '[[ $RC -eq 0 && $(grep -c "^2026-11-01-101010 " "$STORE_REPO/index.md") -eq 1 ]]'
mkdir -p "$TMP_DIR/not-done"
archive --import "$TMP_DIR/not-done"
assert "--import needs a done-<id> dir" '[[ $RC -ne 0 ]]'
archive --import
assert "--import without a dir is a usage error" '[[ $RC -eq 2 ]]'

echo "a run with no summary"
new_repo beta
printf '1\tdone\tw-1\tw/1\tmain\t1\tx\t\n' >"$CREW/board.tsv"
archive
RUN=$(find "$CREW" -maxdepth 1 -type d -name 'done-*' | head -n 1)
ID=${RUN##*/done-}
assert "the index line still names the counts" '[[ $RC -eq 0 && $(tail -n 1 "$WIKI_VAULT/wiki/projects/beta/crew/index.md") == "$ID 1/1 items (no summary)" ]]'

echo "pending ensure"
new_repo gamma
fill_run
printf '4\tassigned\tw-4\tw/4\tmain\t1\tq\t\n' >>"$CREW/board.tsv"
printf '# brief\n' >"$CREW/brief.md"
archive
RUN=$(find "$CREW" -maxdepth 1 -type d -name 'done-*' | head -n 1)
ID=${RUN##*/done-}
assert "with the wiki move pending the run is written beside the crew files" '[[ $RC -eq 0 && $OUT == *"MEMORY pending"* && -f $CREW/runs/$ID/summary.md && -f $CREW/brief.md && ! -d $WIKI_VAULT/wiki/projects/gamma/crew ]]'
assert "the index goes in the crew dir too" '[[ $(cat "$CREW/index.md") == "$ID 2/4 items Run outcome: both slices landed" ]]'

echo "no vault"
new_repo delta
printf '1\tdone\tw-1\tw/1\tmain\t1\tx\t\n' >"$CREW/board.tsv"
printf 'Delta run\n' >"$CREW/summary.md"
OUT=$(cd "$REPO" && WIKI_VAULT= "$ARCHIVE" 2>&1) && RC=0 || RC=$?
RUN=$(find "$CREW" -maxdepth 1 -type d -name 'done-*' | head -n 1)
ID=${RUN##*/done-}
assert "without a vault the run is archived beside the crew files" '[[ $RC -eq 0 && $OUT == *"MEMORY no-vault"* && -f $CREW/runs/$ID/summary.md && $(cat "$CREW/index.md") == "$ID 1/1 items Delta run" ]]'

echo "outside a repo"
OUT=$(cd "$TMP_DIR" && "$ARCHIVE" 2>&1) && RC=0 || RC=$?
assert "outside a repository it fails" '[[ $RC -ne 0 ]]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
