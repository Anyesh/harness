#!/bin/bash
input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$command" ] || exit 0

watched=(rm cp mv ln)

mentioned=()
for name in "${watched[@]}"; do
  if printf '%s' "$command" | grep -qE "(^|[^[:alnum:]_./-])$name([^[:alnum:]_-]|$)"; then
    mentioned+=("$name")
  fi
done
[ ${#mentioned[@]} -gt 0 ] || exit 0

# The Bash tool sources its shell snapshot, so it is the only place that shows the
# aliases the agent's shell really has, unlike this hook's own non-interactive shell.
snapshot_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/shell-snapshots"
snapshot=$(ls -t "$snapshot_dir"/snapshot-* 2>/dev/null | head -1)
[ -n "$snapshot" ] || exit 0

# Quoted strings and heredoc bodies are data, not commands, so blank them out before
# looking for command positions; otherwise a commit message like "x; rm y" is blocked.
strip_literals() {
  awk '
    BEGIN { state = ""; heredoc = ""; pending = "" }
    heredoc != "" {
      line = $0
      if (heredoc_tabs) sub(/^\t+/, "", line)
      if (line == heredoc) heredoc = ""
      print ""
      next
    }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (state == "s") { if (c == "\047") state = ""; continue }
        if (state == "d") { if (c == "\\") i++; else if (c == "\"") state = ""; continue }
        if (c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
        if (c == "\047") { state = "s"; continue }
        if (c == "\"") { state = "d"; continue }
        if (substr($0, i, 3) == "<<<") { out = out "<<<"; i += 2; continue }
        if (substr($0, i, 2) == "<<") {
          rest = substr($0, i + 2)
          if (match(rest, /^-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
            word = substr(rest, 1, RLENGTH)
            pending_tabs = (substr(word, 1, 1) == "-")
            gsub(/^-?[ \t]*[\047"]?|[\047"]$/, "", word)
            pending = word
            out = out "<<"
            i += 1 + RLENGTH
            continue
          }
        }
        out = out c
      }
      print out
      if (pending != "") { heredoc = pending; heredoc_tabs = pending_tabs; pending = "" }
    }'
}
code=$(printf '%s\n' "$command" | strip_literals)

# GNU rm, mv and ln honour whichever of -f and -i comes last, and the alias puts -i
# first, so an explicit -f never prompts; cp -f does not cancel -i.
invocation_prompts() {
  local name=$1 invocation word last
  local -a words
  while IFS= read -r invocation; do
    [ "$name" = cp ] && return 0
    last=i
    read -ra words <<<"${invocation#*"$name"}"
    for word in "${words[@]}"; do
      case "$word" in
        --) break ;;
        --force) last=f ;;
        --interactive*) last=i ;;
        --*) ;;
        -*)
          word=${word#-}
          word=${word//[!fiI]/}
          [ -n "$word" ] && last=${word: -1}
          ;;
      esac
    done
    [ "$last" = f ] || return 0
  done < <(printf '%s\n' "$code" | grep -oE "(^|[;&|(]|\\$\\()[[:space:]]*$name([[:space:]][^;&|)]*|[;&|)]|\$)")
  return 1
}

blocked=()
for name in "${mentioned[@]}"; do
  definition=$(grep -E "^alias (-- )?$name='" "$snapshot" | head -1 | sed -E "s/^alias (-- )?$name='(.*)'\$/\2/")
  [ -n "$definition" ] || continue
  printf '%s' "$definition" | grep -qE '(^| )-[a-zA-Z]*[iI][a-zA-Z]*( |$)|--interactive' || continue
  invocation_prompts "$name" || continue
  blocked+=("$name|$definition")
done
[ ${#blocked[@]} -gt 0 ] || exit 0

for entry in "${blocked[@]}"; do
  name="${entry%%|*}"
  definition="${entry#*|}"
  echo "BLOCKED by pre-bash-interactive-alias: in this shell \`$name\` is aliased to \`$definition\`, so it waits for a y/n answer that never comes. Re-run with \`command $name\` to bypass the alias (for example \`command $name -f path\` when you mean to overwrite or delete without prompts)." >&2
done
exit 2
