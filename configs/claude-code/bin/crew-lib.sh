# shellcheck shell=bash
# Sourced by the crew tools, and by the lead for the slug; these functions are
# the one definition of where a crew lives, what it is called and how its
# files and the host are read.

crew_main() {
  local common
  common=$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$common/.." && pwd -P)
}

# Prints board.tsv with tabs turned into \037 for `IFS=$'\037' read`, because
# a tab IFS collapses empty columns and shifts the rest left. Every line ends in
# a newline, which read needs to see the last row, and the deps column becomes
# comma-separated ids with no spaces or empty entries.
crew_board() {
  [[ -f $1 ]] && awk -F'\t' -v OFS='\037' '
    NF >= 8 {
      n = split($8, parts, ",")
      deps = ""
      for (i = 1; i <= n; i++) {
        gsub(/^ +| +$/, "", parts[i])
        if (parts[i] != "") deps = deps (deps == "" ? "" : ",") parts[i]
      }
      $8 = deps
    }
    { $1 = $1; print }
  ' "$1"
}

crew_report_status() {
  [[ -f $1 ]] || return 0
  sed -n 's/^status:[[:space:]]*//p' "$1" | head -n 1 | tr -d '[:space:]'
}

# Epoch second a live process started, read through ps because macOS has no
# /proc. lstart carries no zone, so both ps and date run in UTC; local time
# would make a DST fall-back hour ambiguous. Needs GNU date for -d.
crew_pid_start() {
  local lstart
  lstart=$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null) || return 1
  [[ -n $lstart ]] || return 1
  TZ=UTC0 date -d "$lstart" +%s
}

# Available memory in MB from /proc/meminfo (Linux) or vm_stat output (Darwin)
# on stdin. Darwin counts free, inactive and speculative pages, since macOS
# keeps inactive pages as reclaimable cache.
crew_mem_avail_mb() {
  case $1 in
  Linux) awk '$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ { printf "%d\n", $2 / 1024; ok = 1; exit } END { exit !ok }' ;;
  Darwin) awk '
    match($0, /page size of [0-9]+ bytes/) { page = substr($0, RSTART + 13, RLENGTH - 19) }
    /^Pages (free|inactive|speculative):/ { v = $NF; sub(/\.$/, "", v); pages += v; n++ }
    END { if (!page || n != 3) exit 1; printf "%d\n", pages * page / 1048576 }
  ' ;;
  *) return 1 ;;
  esac
}

# The 5-minute load average from /proc/loadavg (Linux) or `sysctl -n vm.loadavg`
# (Darwin, `{ 1m 5m 15m }`) on stdin.
crew_load5() {
  local field
  case $1 in
  Linux) field=2 ;;
  Darwin) field=3 ;;
  *) return 1 ;;
  esac
  awk -v f="$field" '
    NR == 1 && (f == 2 || $1 == "{") && $f ~ /^[0-9]+([.][0-9]+)?$/ { print $f; ok = 1 }
    END { exit !ok }
  '
}

# State of a crew-merge marker, items/<id>/merging: `key value` lines pid,
# start, tip, `queued <epoch>` until the merge lock is taken and `merged <sha>`
# once the fast-forward is under way; the last line for a key wins. Prints
# running or queued while the pid still has the recorded start time, otherwise
# `cut <sha>` when a merged line exists, otherwise stale. Fails when the file is
# missing.
crew_merge_state() {
  local fields pid start queued merged
  [[ -f $1 ]] || return 1
  fields=$(awk -v OFS='\037' '
    $1 == "pid" { p = $2 } $1 == "start" { s = $2 } $1 == "queued" { q = 1 } $1 == "merged" { m = $2 }
    END { print p, s, q, m }
  ' "$1") || return 1
  IFS=$'\037' read -r pid start queued merged <<<"$fields"
  if [[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $(crew_pid_start "$pid") == "$start" ]]; then
    if [[ -n $queued ]]; then echo queued; else echo running; fi
  elif [[ $merged =~ ^[0-9a-f]{40,64}$ ]]; then
    echo "cut $merged"
  else
    echo stale
  fi
}

crew_dir() {
  local main
  main=$(crew_main "${1:-.}") || return 1
  printf '%s/.claude/crew\n' "$main"
}

# Heavy slots the crew in dir $1 enables: 0 without a heavy-slots file. Only one
# slot is supported, so any content other than 1 fails with no output.
crew_heavy_slots() {
  local n
  [[ -e $1/heavy-slots ]] || {
    echo 0
    return 0
  }
  n=$(tr -d '[:space:]' <"$1/heavy-slots") || return 1
  [[ $n == 1 ]] || return 1
  echo "$n"
}

# herdr agent names must match [a-z][a-z0-9_-]{0,31}; 21 + 1 + 4 leaves room
# for the longest suffix, -old99.
crew_slug() {
  local main base hash
  main=$(crew_main "${1:-.}") || return 1
  base=$(printf %s "${main##*/}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
  [[ $base == [a-z]* ]] || base="r-$base"
  hash=$(printf %s "$main" | sha1sum | cut -c1-4)
  printf '%s-%s\n' "${base:0:21}" "$hash"
}
