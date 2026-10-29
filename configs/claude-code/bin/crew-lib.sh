# shellcheck shell=bash
# Sourced by crew-role, crew-merge and crew-sweep, and by the lead for the slug;
# these functions are the one definition of where a crew lives and what it is called.

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

crew_dir() {
  local main
  main=$(crew_main "${1:-.}") || return 1
  printf '%s/.claude/crew\n' "$main"
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
