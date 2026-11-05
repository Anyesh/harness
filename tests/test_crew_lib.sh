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
assert "report word is the first status line's leading word" '[[ $(crew_report_word "$TMP_DIR/report.md") == question ]]'
printf 'status: rate-limited resets 3pm\n' >"$TMP_DIR/word.md"
assert "report word stops at the first space" '[[ $(crew_report_word "$TMP_DIR/word.md") == rate-limited ]]'
printf 'status:done   \n' >"$TMP_DIR/word.md"
assert "report word ignores trailing spaces" '[[ $(crew_report_word "$TMP_DIR/word.md") == done ]]'
printf 'status: Done\n' >"$TMP_DIR/word.md"
assert "report word is empty when the status starts with no lowercase word" '[[ -z $(crew_report_word "$TMP_DIR/word.md") ]]'
assert "a missing report has an empty word" '[[ -z $(crew_report_word "$TMP_DIR/none.md") ]]'

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

echo "heavy queue"
HC="$TMP_DIR/heavycrew"
HQ="$HC/heavy.queue"
mkdir -p "$HQ"
sleep 60 &
live=$!
S=$(crew_pid_start "$live")
sleep 0 &
dead=$!
wait "$dead"
ticket() { printf '%s/%020d.%s.%s' "$HQ" "$(($1 * 1000000 + 7))" "$2" "$3"; }
assert "a ticket whose pid started no later than the ticket is live" 'crew_heavy_ticket_live "$(ticket "$S" "$live" w)"'
assert "a ticket older than its pid's process is not live" '! crew_heavy_ticket_live "$(ticket "$((S - 5))" "$live" w)"'
assert "a ticket with a dead pid is not live" '! crew_heavy_ticket_live "$(ticket "$S" "$dead" w)"'
assert "a ticket with no pid field is not live" '! crew_heavy_ticket_live "$HQ/00000000000000000001" && ! crew_heavy_ticket_live "$HQ/x.$live.w"'

assert "a merge- holder has priority" 'crew_heavy_priority "$HC" merge-3 "$EPOCHSECONDS"'
assert "a plain holder has no priority" '! crew_heavy_priority "$HC" 3 "$EPOCHSECONDS"'
printf '12\n 4 \n' >"$HC/heavy-priority"
assert "a holder listed as a whole line in heavy-priority has priority" 'crew_heavy_priority "$HC" 12 "$EPOCHSECONDS" && crew_heavy_priority "$HC" 4 "$EPOCHSECONDS"'
assert "a holder that is only part of a heavy-priority line has none" '! crew_heavy_priority "$HC" 1 "$EPOCHSECONDS" && ! crew_heavy_priority "$HC" 123 "$EPOCHSECONDS"'
rm "$HC/heavy-priority"
assert "a ticket CREW_HEAVY_AGE old has priority, defaulting to 3600 s" 'crew_heavy_priority "$HC" 3 "$((EPOCHSECONDS - 3600))" && ! crew_heavy_priority "$HC" 3 "$((EPOCHSECONDS - 3500))"'
assert "CREW_HEAVY_AGE sets the age that gives priority" '(CREW_HEAVY_AGE=10 crew_heavy_priority "$HC" 3 "$((EPOCHSECONDS - 10))") && ! (CREW_HEAVY_AGE=10 crew_heavy_priority "$HC" 3 "$((EPOCHSECONDS - 5))")'

assert "a free slot has an empty hold" 'out=$(crew_heavy_hold "$HC") && [[ -z $out ]]'
mkdir "$HC/heavy.lock"
printf 'merge-3\tmerge gate\t1700000000\n' >"$HC/heavy.lock/holder"
assert "a hold is the holder and its epoch, tab-separated" '[[ $(crew_heavy_hold "$HC") == "merge-3	1700000000" ]]'

: >"$(ticket "$S" "$live" a)"
: >"$(ticket "$((S + 50))" "$live" merge-b)"
: >"$(ticket "$((S + 100))" "$live" c.x)"
: >"$(ticket "$((S + 200))" "$live" d)"
: >"$(ticket "$S" "$dead" e)"
printf 'd\n' >"$HC/heavy-priority"
assert "waiters list priority tickets by age, then the rest by age, as holder and epoch" '[[ $(crew_heavy_waiters "$HC") == "merge-b	$((S + 50))"$'\''\n'\''"d	$((S + 200))"$'\''\n'\''"a	$S"$'\''\n'\''"c.x	$((S + 100))" ]]'
assert "an aged ticket joins the priority class ahead of younger merges" '[[ $(CREW_HEAVY_AGE=0 crew_heavy_waiters "$HC" | cut -f1 | paste -sd" " -) == "a merge-b d c.x" ]]'
assert "listing waiters deletes no ticket" '[[ $(find "$HQ" -type f | wc -l) -eq 5 ]]'
kill "$live"
wait "$live" 2>/dev/null || true

echo "usage files"
export XDG_STATE_HOME="$TMP_DIR/state"
U="$XDG_STATE_HOME/harness/usage/sessions"
mkdir -p "$U"
NOW=$EPOCHSECONDS
B=$(((NOW / 300 + 12) * 300))
W=$((NOW + 5 * 86400))
session() { printf '{"profile":"%s","context_tokens":%s,"context_window":%s,"session":{"pct":%s,"resets":%s},"week":{"pct":%s,"resets":%s}}\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8" >"$U/$1.json"; }
session busy ero 420000 1000000 88 "$((B + 1))" 40 "$W"
session idle ero 9000 1000000 61 "$((B - 1))" 39 "$W"
session old ero 1000 1000000 99 "$((NOW - 60))" 10 "$((NOW - 60))"
session main default null null null null 50 "$W"
assert "session usage gives profile, context tokens and window" '[[ $(crew_session_usage busy) == "ero	420000	1000000" ]]'
assert "null context fields read as ?" '[[ $(crew_session_usage main) == "default	?	?" ]]'
assert "a missing session file fails" '! crew_session_usage nosuch >/dev/null'
assert "a session id with odd characters fails" '! crew_session_usage "../busy" >/dev/null'
assert "profile usage takes the highest figure in the latest window, within 300 s of jitter" '[[ $(crew_profile_usage ero) == "88 $((B + 1)) 40 $W" ]]'
assert "a passed or null window reads ?" '[[ $(crew_profile_usage default) == "? ? 50 $W" ]]'
assert "a profile with no session files reads ?" '[[ $(crew_profile_usage nobody) == "? ? ? ?" ]]'
printf '{"profile":"ero","session":{"pct":"lots","resets":%s}}\n' "$((B + 5))" >"$U/strange.json"
printf '{"profile":"ero",' >"$U/torn.json"
assert "non-integer and unparseable files are ignored" '[[ $(crew_profile_usage ero) == "88 $((B + 1)) 40 $W" ]]'
rm -f "$U"/*.json
assert "an empty usage dir reads ?" '[[ $(crew_profile_usage ero) == "? ? ? ?" ]]'

echo "thresholds"
T="$TMP_DIR/thresholds"
printf '# c\n\nCREW_MEM_MIN_MB=512\nCREW_CONTEXT_K=300\nCREW_WORKERS_PER_PROFILE=80%%\nCREW_BOGUS=1\nnope\n' >"$T"
crew_read_thresholds "$T"
assert "a file value applies" '[[ $(crew_threshold CREW_MEM_MIN_MB 1024) == 512 && $(crew_threshold CREW_CONTEXT_K 400) == 300 ]]'
assert "a missing key takes the default" '[[ $(crew_threshold CREW_SESSION_HARD_PCT 90) == 90 ]]'
assert "an environment value wins over the file" '[[ $(CREW_CONTEXT_K=350 crew_threshold CREW_CONTEXT_K 400) == 350 ]]'
assert "an empty environment value falls back to the file" '[[ $(CREW_CONTEXT_K= crew_threshold CREW_CONTEXT_K 400) == 300 ]]'
assert "a non-integer value for a whole-number key takes the default" '[[ $(crew_threshold CREW_WORKERS_PER_PROFILE 5) == 5 && $(CREW_CONTEXT_K=eighty crew_threshold CREW_CONTEXT_K 400) == 400 && $(CREW_CONTEXT_K=80.5 crew_threshold CREW_CONTEXT_K 400) == 400 ]]'
assert "bad lines are collected with their line numbers" '[[ ${#crew_threshold_errors[@]} -eq 2 && ${crew_threshold_errors[0]} == "thresholds line 6: unknown key CREW_BOGUS" && ${crew_threshold_errors[1]} == "thresholds line 7: not KEY=value: nope" ]]'
crew_read_thresholds "$TMP_DIR/none"
assert "a missing file clears earlier values" '[[ $(crew_threshold CREW_MEM_MIN_MB 1024) == 1024 && ${#crew_threshold_errors[@]} -eq 0 ]]'
if command -v zsh >/dev/null; then
  assert "crew-lib still sources in zsh" '[[ $(cd "$MAIN" && zsh -c ". \"$REPO_ROOT/configs/claude-code/bin/crew-lib.sh\" && crew_dir") == "$MAIN/.claude/crew" ]]'
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
