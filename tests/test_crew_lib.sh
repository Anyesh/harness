#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
trap 'command rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

new_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

hash4() { printf %s "$1" | sha1sum | cut -c1-4; }

MAIN="$TMP_DIR/My Repo.Name"
new_repo "$MAIN"
MAIN=$(cd "$MAIN" && pwd -P)
mkdir -p "$MAIN/sub/dir"
git -C "$MAIN" worktree add -q -b w/1 "$MAIN/.claude/worktrees/w-1"
ln -s "$MAIN" "$TMP_DIR/link"

assert "main checkout resolves to itself" '[[ $(cd "$MAIN" && crew_main) == "$MAIN" ]]'
assert "a subdirectory resolves to the main checkout" '[[ $(cd "$MAIN/sub/dir" && crew_main) == "$MAIN" ]]'
assert "a linked worktree resolves to the main checkout" '[[ $(cd "$MAIN/.claude/worktrees/w-1" && crew_main) == "$MAIN" ]]'
assert "a symlinked path resolves to the real main checkout" '[[ $(cd "$TMP_DIR/link" && crew_main) == "$MAIN" ]]'
assert "an explicit dir argument is honoured" '[[ $(cd "$TMP_DIR" && crew_main "$MAIN/sub") == "$MAIN" ]]'
assert "outside a repo crew_main fails" '! (cd "$TMP_DIR" && crew_main >/dev/null 2>&1)'
assert "crew_dir is .claude/crew of the main checkout" '[[ $(cd "$MAIN/.claude/worktrees/w-1" && crew_dir) == "$MAIN/.claude/crew" ]]'

expected="my-repo-name-$(hash4 "$MAIN")"
assert "slug lowercases, replaces odd characters and appends the path hash" '[[ $(cd "$MAIN" && crew_slug) == "$expected" ]]'
assert "slug is the same from a worktree" '[[ $(cd "$MAIN/.claude/worktrees/w-1" && crew_slug) == "$expected" ]]'

DIGIT="$TMP_DIR/9lives"
new_repo "$DIGIT"
DIGIT=$(cd "$DIGIT" && pwd -P)
assert "slug gets an r- prefix when it does not start with a letter" '[[ $(cd "$DIGIT" && crew_slug) == "r-9lives-$(hash4 "$DIGIT")" ]]'

LONG="$TMP_DIR/a-very-long-repository-basename-indeed"
new_repo "$LONG"
LONG=$(cd "$LONG" && pwd -P)
slug=$(cd "$LONG" && crew_slug)
assert "slug base is cut to 21 characters" '[[ $slug == "a-very-long-repositor-$(hash4 "$LONG")" ]]'
assert "slug is at most 26 characters" '[[ ${#slug} -le 26 ]]'
assert "the longest agent name fits herdr's limit" '[[ "$slug-old99" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]'

printf '1\topen\t\tw/1\tmain\t0\tfirst\n2\topen\t\tw/2\tmain\t0\tsecond\t 1 , ,3 ' >"$TMP_DIR/board.tsv"
rows=$(crew_board "$TMP_DIR/board.tsv" | while IFS=$'\037' read -r id _ owner _ _ _ title deps; do printf '%s|%s|%s|%s\n' "$id" "$owner" "$title" "$deps"; done)
assert "crew_board keeps empty columns in place" '[[ $(head -n 1 <<<"$rows") == "1||first|" ]]'
assert "crew_board keeps a last row without a newline and normalises its deps" '[[ $(tail -n 1 <<<"$rows") == "2||second|1,3" ]]'

printf 'summary\nstatus:  question \nstatus: done\n' >"$TMP_DIR/report.md"
assert "report status is the first status line, trimmed" '[[ $(crew_report_status "$TMP_DIR/report.md") == question ]]'
assert "a missing report has an empty status" '[[ -z $(crew_report_status "$TMP_DIR/none.md") ]]'

SLOTS="$TMP_DIR/slots"
mkdir -p "$SLOTS"
assert "no heavy-slots file means 0 heavy slots" '[[ $(crew_heavy_slots "$SLOTS") == 0 ]]'
printf ' 1\n' >"$SLOTS/heavy-slots"
assert "heavy-slots holding 1 means 1 heavy slot" '[[ $(crew_heavy_slots "$SLOTS") == 1 ]]'
for bad in 2 0 '' x; do
  printf '%s\n' "$bad" >"$SLOTS/heavy-slots"
  assert "heavy-slots holding '$bad' is refused" '! out=$(crew_heavy_slots "$SLOTS") && [[ -z $out ]]'
done

before=$EPOCHSECONDS
sleep 30 &
live=$!
started=$(crew_pid_start "$live")
assert "pid start is the epoch second the process started" '[[ $started =~ ^[0-9]+$ ]] && ((started >= before - 1 && started <= EPOCHSECONDS))'
assert "pid start is the same on every read" '[[ $(crew_pid_start "$live") == "$started" ]]'
assert "pid start is unaffected by TZ" '[[ $(TZ=America/New_York crew_pid_start "$live") == "$started" ]]'
kill "$live"
wait "$live" 2>/dev/null || true
assert "pid start fails with no output for a dead pid" '! out=$(crew_pid_start "$live") && [[ -z $out ]]'

sleep 30 &
live=$!
live_start=$(crew_pid_start "$live")
sleep 0 &
dead=$!
wait "$dead"
m="$TMP_DIR/merging"
sha=$(printf '%040d' 7)
printf 'pid %s\nstart %s\ntip %s\n' "$live" "$live_start" "$sha" >"$m"
assert "a marker whose pid lives with the recorded start is running" '[[ $(crew_merge_state "$m") == running ]]'
printf 'pid %s\nstart %s\ntip %s\nqueued 1\n' "$live" "$live_start" "$sha" >"$m"
assert "a live marker with a queued line is queued" '[[ $(crew_merge_state "$m") == queued ]]'
printf 'pid %s\nstart %s\ntip %s\nmerged %s\n' "$live" "$live_start" "$sha" "$sha" >"$m"
assert "a live marker with a merged line is still running" '[[ $(crew_merge_state "$m") == running ]]'
printf 'pid %s\nstart %s\ntip %s\nmerged %s\n' "$live" "$((live_start + 1))" "$sha" "$sha" >"$m"
assert "a reused pid with a merged line is cut at that sha" '[[ $(crew_merge_state "$m") == "cut $sha" ]]'
printf 'pid %s\nstart %s\ntip %s\n' "$dead" "$live_start" "$sha" >"$m"
assert "a dead pid without a merged line is stale" '[[ $(crew_merge_state "$m") == stale ]]'
printf 'garbage\n' >"$m"
assert "an unparseable marker is stale" '[[ $(crew_merge_state "$m") == stale ]]'
assert "a missing marker fails with no output" '! out=$(crew_merge_state "$TMP_DIR/none") && [[ -z $out ]]'
kill "$live"
wait "$live" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
