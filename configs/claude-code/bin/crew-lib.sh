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

# The leading [a-z-] run of the first status: line, so `rate-limited resets
# 3pm` gives rate-limited; crew-sweep's snapshot awk applies the same rule.
crew_report_word() {
  local line
  [[ -f $1 ]] || return 0
  line=$(sed -n 's/^status:[[:space:]]*//p' "$1" | head -n 1)
  [[ $line =~ ^[a-z-]+ ]] && echo "${BASH_REMATCH[0]}"
  return 0
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

# The full line's avg60 from /proc/pressure/io text on stdin: the share of the
# last 60 s in which every runnable task waited on I/O.
crew_io_full_avg60() {
  awk '
    $1 == "full" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=[0-9]+([.][0-9]+)?$/) { print substr($i, 7); ok = 1 } exit }
    END { exit !ok }
  '
}

# Up to five names of processes in state D (waiting on disk) from
# `ps -eo stat=,comm=` output on stdin, most frequent first as `name xN`, or
# `none seen`. Names may hold spaces; kworker/<n>:<m> threads count as kworker.
crew_dstate_summary() {
  awk '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line !~ /^D/ || !match(line, /[ \t]+/)) next
      name = substr(line, RSTART + RLENGTH)
      sub(/[ \t]+$/, "", name)
      if (name ~ /^kworker\//) name = "kworker"
      if (name != "") n[name]++
    }
    END { for (k in n) printf "%d\t%s\n", n[k], k }
  ' | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr -k2 | awk -F'\t' '
    NR <= 5 { s = s (NR > 1 ? ", " : "") $2 ($1 > 1 ? " x" $1 : "") }
    END { print (s == "" ? "none seen" : s) }
  '
}

crew_usage_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/harness/usage/sessions"
}

# Profile, context tokens and context window of one session, tab-separated,
# from the file the statusline writes; a number that is not a whole number
# (null, missing) prints as ?, so nothing but digits reaches bash arithmetic.
crew_session_usage() {
  local file
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  file="$(crew_usage_dir)/$1.json"
  [[ -f $file ]] || return 1
  jq -r '
    def n: if type == "number" and . >= 0 and . == floor then tostring else "?" end;
    [(.profile | if type == "string" and test("^[A-Za-z0-9_.-]+$") then . else "?" end),
     (.context_tokens | n), (.context_window | n)] | @tsv
  ' "$file" 2>/dev/null
}

# `session_pct session_resets week_pct week_resets` for one profile, merged
# over every session file on it: per window, among figures whose reset is still
# ahead, the highest within 300 s of the latest reset, since sessions report a
# window's reset a few seconds apart and an idle session keeps its older,
# lower figure. A window with no such figure prints ? ?. The second argument
# overrides the current epoch second.
crew_profile_usage() {
  local profile=$1 now=${2:-$EPOCHSECONDS} dir files filter f
  dir=$(crew_usage_dir)
  files=()
  if [[ -d $dir ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name '*.json')
  fi
  filter='
    def int: type == "number" and . >= 0 and . == floor;
    def window(w): [.[] | objects | select(.profile == $p) | .[w]
        | select(type == "object" and (.pct | int) and (.resets | int) and .resets > $now)] as $xs
      | if ($xs | length) == 0 then ["?", "?"]
        else ($xs | map(.resets) | max) as $r
          | [($xs | map(select(.resets >= $r - 300) | .pct) | max | tostring), ($r | tostring)]
        end;
    window("session") + window("week") | join(" ")
  '
  if ((${#files[@]} == 0)); then
    echo "? ? ? ?"
  elif ! jq -rs --arg p "$profile" --argjson now "$now" "$filter" "${files[@]}" 2>/dev/null; then
    for f in "${files[@]}"; do jq -c . "$f" 2>/dev/null; done |
      jq -rs --arg p "$profile" --argjson now "$now" "$filter"
  fi
}

crew_threshold_keys=(CREW_DISK_MIN_GB CREW_MEM_MIN_MB CREW_LOAD_PER_CPU CREW_IO_FULL_PCT
  CREW_SESSION_SOFT_PCT CREW_SESSION_HARD_PCT CREW_WEEK_SOFT_PCT CREW_WEEK_HARD_PCT
  CREW_CONTEXT_K CREW_OPENCODE_CONTEXT_K CREW_WORKERS_PER_PROFILE)
crew_threshold_whole=" CREW_SESSION_SOFT_PCT CREW_SESSION_HARD_PCT CREW_WEEK_SOFT_PCT CREW_WEEK_HARD_PCT CREW_CONTEXT_K CREW_OPENCODE_CONTEXT_K CREW_WORKERS_PER_PROFILE "
declare -gA crew_threshold_file=()
crew_threshold_errors=()

# Reads a crew thresholds file into crew_threshold_file, parsed and never
# sourced, collecting each bad line in crew_threshold_errors for the caller to
# report or ignore. A missing file clears both.
crew_read_thresholds() {
  local line key n=0
  crew_threshold_file=()
  crew_threshold_errors=()
  [[ -f $1 ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ ! $line =~ ^[[:space:]]*(#|$) ]] || continue
    if [[ $line != *=* ]]; then
      crew_threshold_errors+=("thresholds line $n: not KEY=value: $line")
      continue
    fi
    key=${line%%=*}
    if [[ " ${crew_threshold_keys[*]} " == *" $key "* ]]; then
      crew_threshold_file[$key]=${line#*=}
    else
      crew_threshold_errors+=("thresholds line $n: unknown key $key")
    fi
  done <"$1"
}

crew_threshold_raw() {
  local v=
  [[ " ${crew_threshold_keys[*]} " == *" $1 "* ]] || return 1
  eval "v=\${$1:-}"
  [[ -n $v ]] || v=${crew_threshold_file[$1]:-}
  printf '%s\n' "$v"
}

# A threshold's value, or the default given; a whole-number key with any other
# value also takes the default, since crew-sweep compares it in bash.
crew_threshold() {
  local v
  v=$(crew_threshold_raw "$1") || return 1
  [[ -n $v ]] || v=$2
  if [[ $crew_threshold_whole == *" $1 "* && ! $v =~ ^[0-9]+$ ]]; then v=$2; fi
  printf '%s\n' "$v"
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

# A report-only item lands nothing, so its done report stands in for a merge.
crew_report_only() {
  [[ -f $1/items/$2/report-only ]]
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

# A heavy.queue ticket, `<epoch microseconds>.<pid>.<holder>`, is live while its
# pid runs a process that started no later than the ticket, so a pid reused by
# a newer process does not hold the queue.
crew_heavy_ticket_live() {
  local name=${1##*/} pid start
  pid=${name#*.}
  pid=${pid%%.*}
  [[ ${name%%.*} =~ ^[0-9]+$ && $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  start=$(crew_pid_start "$pid") || return 1
  ((start <= 10#${name%%.*} / 1000000))
}

crew_heavy_priority() {
  local age=${CREW_HEAVY_AGE:-3600}
  [[ $age =~ ^[0-9]+$ ]] || age=3600
  [[ $2 == merge-* ]] && return 0
  if [[ -f $1/heavy-priority ]] && awk -v h="$2" '{ gsub(/^[ \t\r]+|[ \t\r]+$/, "") } $0 == h { found = 1; exit } END { exit !found }' "$1/heavy-priority"; then
    return 0
  fi
  ((EPOCHSECONDS - $3 >= age))
}

crew_heavy_hold() {
  [[ -f $1/heavy.lock/holder ]] || return 0
  awk -F'\t' -v OFS='\t' 'NR == 1 { print $1, $3 }' "$1/heavy.lock/holder"
}

# Live tickets of crew $1 in serving order as `class<TAB>holder<TAB>epoch
# seconds<TAB>path`, class 0 for priority and 1 for normal; each class is
# served oldest first.
crew_heavy_queue() {
  local t name holder epoch tab=$'\t' first=() rest=()
  for t in "$1"/heavy.queue/*; do
    [[ -e $t ]] && crew_heavy_ticket_live "$t" || continue
    name=${t##*/}
    holder=${name#*.}
    holder=${holder#*.}
    epoch=$((10#${name%%.*} / 1000000))
    if crew_heavy_priority "$1" "$holder" "$epoch"; then
      first+=("0$tab$holder$tab$epoch$tab$t")
    else
      rest+=("1$tab$holder$tab$epoch$tab$t")
    fi
  done
  ((${#first[@]} + ${#rest[@]})) || return 0
  printf '%s\n' "${first[@]}" "${rest[@]}"
}

crew_heavy_waiters() {
  crew_heavy_queue "$1" | cut -f2,3
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
