#!/bin/bash
# shell_code [keep] < command > code
#
# Reduces a shell command line to the text that runs as commands, so guards
# stop matching words inside commit messages, grep patterns, heredocs fed to
# python and the like. Quoted strings and heredoc bodies are blanked; $(...)
# inside double quotes stays, because it runs.
#
# With "keep", strings and heredocs that another shell will execute (sh -c,
# bash -c, ssh, eval, heredocs into a shell or ssh, `cat <<EOF | bash`) are
# kept and fenced with " ; " so their first word sits at a command position.
# Danger guards want that; the alias guard does not, because those shells are
# non-interactive and never expand the user's aliases.
#
# Not a full parser: nested quoting inside $(...) inside an executed string and
# backslash-escaped heredoc delimiters are not tracked.

# ERE prefix meaning "a command starts here": line start, a separator, or a
# wrapper such as sudo or timeout. For grep -E over shell_code output.
# shellcheck disable=SC2034
SHELL_CMD_START='(^|[;&|({!]|\$\(|\bsudo(\s+-\S+)*\s|\bdoas\s|\bexec\s|\bnohup\s|\btimeout\s+\S+\s)\s*'

shell_code() {
  local keep=0
  [ "${1:-}" = keep ] && keep=1
  awk -v keep="$keep" '
    function prefix() { return "(^|[;&|(!{]|\\$\\()[ \t]*((sudo|doas|exec|nohup|env)([ \t]+-[^ \t]+)*[ \t]+|timeout[ \t]+[^ \t]+[ \t]+)*" }
    function feeds_shell(s) {
      return s ~ (prefix() "(ba|z|da|k)?sh([ \t]+-[a-zA-Z]+)*[ \t]+-[a-zA-Z]*c[a-zA-Z]*[ \t]*$") ||
             s ~ (prefix() "ssh([ \t]+[^;&|]*)?[ \t]$") ||
             s ~ (prefix() "eval[ \t]*$")
    }
    function heredoc_runs(s, rest) {
      return s ~ (prefix() "((ba|z|da|k)?sh|ssh)([ \t][^;&|]*)?[ \t]*$") ||
             rest ~ /\|[ \t]*(sudo[ \t]+)?(ba|z|da|k)?sh([ \t]|$)/
    }
    BEGIN { state = ""; heredoc = ""; pending = ""; exec = 0; in_sub = 0 }
    heredoc != "" {
      line = $0
      if (heredoc_tabs) sub(/^\t+/, "", line)
      if (line == heredoc) { heredoc = ""; print ""; next }
      print ((keep && heredoc_exec) ? $0 : "")
      next
    }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (state == "s") {
          if (c == "\047") { state = ""; if (exec) { out = out " ; "; exec = 0 } }
          else if (exec) out = out c
          continue
        }
        if (state == "d") {
          if (c == "\\") { if (exec) out = out substr($0, i + 1, 1); i++; continue }
          if (c == "\"") { state = ""; if (exec) { out = out " ; "; exec = 0 }; continue }
          if (substr($0, i, 2) == "$(") {
            out = out " ; "; state = ""; in_sub = 1; depth = 1; sub_exec = exec; exec = 0; i++
            continue
          }
          if (exec) out = out c
          continue
        }
        if (in_sub) {
          if (c == "(") depth++
          else if (c == ")" && --depth == 0) {
            in_sub = 0; state = "d"; exec = sub_exec; out = out " ; "
            continue
          }
        }
        if (c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
        if (c == "\047" || c == "\"") {
          state = (c == "\047") ? "s" : "d"
          if (keep && feeds_shell(out)) { exec = 1; out = out " ; " }
          continue
        }
        if (substr($0, i, 3) == "<<<") { out = out "<<<"; i += 2; continue }
        if (substr($0, i, 2) == "<<") {
          rest = substr($0, i + 2)
          if (match(rest, /^-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
            word = substr(rest, 1, RLENGTH)
            pending_tabs = (substr(word, 1, 1) == "-")
            pending_exec = heredoc_runs(out, substr(rest, RLENGTH + 1))
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
      if (pending != "") {
        heredoc = pending; heredoc_tabs = pending_tabs; heredoc_exec = pending_exec; pending = ""
      }
    }'
}
