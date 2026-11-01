#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CR="$REPO_ROOT/configs/claude-code/bin/crew-resources"
# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

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
    printf '        out: %s\n        err: %s\n' "${OUT//$'\n'/$'\n             '}" "${ERR//$'\n'/$'\n             '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'command rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
git init -q "$REPO"
CREW="$REPO/.claude/crew"
mkdir -p "$CREW"
export CREW_RUNS_DIR="$TMP_DIR/runs"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
DF_LOG="$TMP_DIR/df.log"
export DF_LOG

# Fake df: logs each path, then acts on FAKE_DF (pass, fail, garbage, hang or
# spaces); pass and log hand the call to the real df.
REAL_DF=$(command -v df)
export REAL_DF
cat >"$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >>"$DF_LOG"
case ${FAKE_DF:-pass} in
fail)
  echo "df: ${!#}: Stale file handle" >&2
  exit 1
  ;;
garbage) echo "no table here" ;;
hang) exec sleep 30 ;;
spaces)
  echo "Filesystem    1024-blocks      Used Available Capacity Mounted on"
  echo "map auto_home   976490576 600000000  10485760    37%    /Volumes/My Disk"
  ;;
*) exec "$REAL_DF" "$@" ;;
esac
EOF
chmod +x "$FAKE_BIN/df"

OUT=
ERR=
RC=0
RUN_DIR=$REPO
run() {
  RC=0
  OUT=$(cd "$RUN_DIR" && env "$@" 2>"$TMP_DIR/err") || RC=$?
  ERR=$(<"$TMP_DIR/err")
}
QUIET_ENV=(CREW_DISK_MIN_GB=0 CREW_MEM_MIN_MB=0 CREW_LOAD_PER_CPU=1000000)
has() { grep -qxF -- "$1" <<<"$OUT"; }
has_re() { grep -qE -- "$1" <<<"$OUT"; }
count_re() { grep -cE -- "$1" <<<"$OUT" || true; }

echo "parsers"
meminfo=$'MemTotal:       32768000 kB\nMemFree:         1000000 kB\nMemAvailable:   12345678 kB\n'
assert "meminfo gives MemAvailable in MB" '[[ $(crew_mem_avail_mb Linux <<<"$meminfo") == 12056 ]]'
vmstat16=$'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                                3046.\nPages active:                            180467.\nPages inactive:                          178604.\nPages speculative:                         1914.\nPages throttled:                              0.\nPages wired down:                        124361.\n'
assert "vm_stat with 16 KB pages counts free, inactive and speculative" '[[ $(crew_mem_avail_mb Darwin <<<"$vmstat16") == 2868 ]]'
vmstat4=${vmstat16/16384/4096}
assert "vm_stat takes the page size from its header" '[[ $(crew_mem_avail_mb Darwin <<<"$vmstat4") == 717 ]]'
assert "vm_stat without a page size fails" '! crew_mem_avail_mb Darwin <<<"${vmstat16#*$'"'"'\n'"'"'}" >/dev/null'
assert "meminfo without MemAvailable fails" '! crew_mem_avail_mb Linux <<<"MemTotal: 1 kB" >/dev/null'
assert "Linux loadavg gives the 5-minute field" '[[ $(crew_load5 Linux <<<"0.52 1.58 0.59 1/1234 5678") == 1.58 ]]'
assert "Darwin vm.loadavg gives the 5-minute field" '[[ $(crew_load5 Darwin <<<"{ 1.86 2.03 2.11 }") == 2.03 ]]'
assert "unparseable load fails" '! crew_load5 Linux <<<"busy" >/dev/null && ! crew_load5 Darwin <<<"1.86 2.03 2.11" >/dev/null'
assert "an unknown OS fails" '! crew_load5 Plan9 <<<"0.1 0.2 0.3" >/dev/null && ! crew_mem_avail_mb Plan9 <<<"$meminfo" >/dev/null'

echo "real probes"
run "${QUIET_ENV[@]}" "$CR"
assert "thresholds nothing can cross print nothing and exit 0" '[[ $RC -eq 0 && -z $OUT && -z $ERR ]]'

mount_of() { "$REAL_DF" -Pk -- "$1" | awk 'NR == 2 && match($0, / [0-9]+% +/) {print substr($0, RSTART + RLENGTH)}'; }
repo_mount=$(mount_of "$REPO")
run "${QUIET_ENV[@]}" CREW_DISK_MIN_GB=999999 "$CR"
assert "a disk under its threshold prints mount, free GB and the first path on it" 'has_re "^disk $repo_mount [0-9]+ GB free, critical \($REPO\)$" && [[ $RC -eq 0 ]]'
assert "each mount is reported once" '[[ $(count_re "^disk $repo_mount ") -eq 1 ]]'

run "${QUIET_ENV[@]}" CREW_DISK_MIN_GB=999999 "$CR" "$TMP_DIR/given"
assert "paths given come first" 'has_re "^disk $repo_mount [0-9]+ GB free, critical \($TMP_DIR/given\)$"'

run "${QUIET_ENV[@]}" CREW_MEM_MIN_MB=999999999 "$CR"
assert "memory under its threshold prints the MB available" 'has_re "^memory [0-9]+ MB available$" && [[ $(count_re .) -eq 1 ]]'

run "${QUIET_ENV[@]}" CREW_LOAD_PER_CPU=-1 "$CR"
cpus=$(getconf _NPROCESSORS_ONLN)
assert "load over its threshold prints the 5-minute load and the CPU count" 'has_re "^load [0-9]+([.][0-9]+)? over $cpus CPUs$" && [[ $(count_re .) -eq 1 ]]'

run "${QUIET_ENV[@]}" CREW_MEM_MIN_MB=lots "$CR"
assert "a threshold that is not a number is a failure naming it" '[[ $RC -eq 1 ]] && grep -q "CREW_MEM_MIN_MB is not a number: lots" <<<"$ERR"'

echo "probed paths"
printf '%s\n\n%s\n' "$TMP_DIR/watched/not/built/yet" "$TMP_DIR/runs" >"$CREW/watch-paths"
: >"$DF_LOG"
run "${QUIET_ENV[@]}" PATH="$FAKE_BIN:$PATH" "$CR" "$TMP_DIR/arg"
assert "a missing path is probed at its nearest existing ancestor" 'grep -qxF "$TMP_DIR" "$DF_LOG" && [[ $RC -eq 0 ]]'
assert "the main checkout and an existing watch path are probed" 'grep -qxF "$REPO" "$DF_LOG"'
assert "blank watch-paths lines are skipped" '! grep -qx "" "$DF_LOG"'
rm "$CREW/watch-paths"
: >"$DF_LOG"
run "${QUIET_ENV[@]}" PATH="$FAKE_BIN:$PATH" CREW_RUNS_DIR="$TMP_DIR/elsewhere/runs" "$CR"
assert "the runs dir is probed" 'grep -qxF "$TMP_DIR" "$DF_LOG"'

echo "df failures"
run "${QUIET_ENV[@]}" CREW_MEM_MIN_MB=999999999 PATH="$FAKE_BIN:$PATH" FAKE_DF=fail "$CR"
assert "a failing df exits 1 and names the path and error" '[[ $RC -eq 1 ]] && grep -qF "$REPO" <<<"$ERR" && grep -q "Stale file handle" <<<"$ERR"'
assert "the other probes still report after a df failure" 'has_re "^memory [0-9]+ MB available$"'
run "${QUIET_ENV[@]}" PATH="$FAKE_BIN:$PATH" FAKE_DF=garbage "$CR"
assert "unparseable df output is a failure" '[[ $RC -eq 1 && -z $OUT ]] && grep -q "cannot parse" <<<"$ERR"'
run "${QUIET_ENV[@]}" CREW_DISK_MIN_GB=20 PATH="$FAKE_BIN:$PATH" FAKE_DF=spaces "$CR"
assert "a mount name with spaces is kept whole, above a quarter of the threshold not critical" 'has "disk /Volumes/My Disk 10 GB free ($REPO)"'
t0=$SECONDS
RUN_DIR=$TMP_DIR
run "${QUIET_ENV[@]}" PATH="$FAKE_BIN:$PATH" FAKE_DF=hang CREW_RUNS_DIR="$TMP_DIR" "$CR"
RUN_DIR=$REPO
assert "a hung df is stopped after 10 seconds and named" '((SECONDS - t0 < 20)) && [[ $RC -eq 1 ]] && grep -q "timed out" <<<"$ERR"'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
