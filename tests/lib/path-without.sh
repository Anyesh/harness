# shellcheck shell=bash
# path_without <command> <scratch dir>: prints PATH with every directory that
# holds <command> replaced by a mirror of its other entries, so a test can run
# as if <command> were not installed even when it shares a directory (such as
# /opt/homebrew/bin) with tools the test needs.
path_without() {
  local cmd=$1 scratch=$2 dir mirror f out= n=0
  local IFS=:
  for dir in $PATH; do
    if [[ -n $dir && -x $dir/$cmd ]]; then
      n=$((n + 1))
      mirror=$scratch/path-without-$n
      mkdir -p "$mirror"
      for f in "$dir"/*; do
        [[ ${f##*/} == "$cmd" ]] || ln -sf "$f" "$mirror/"
      done
      dir=$mirror
    fi
    out+=${out:+:}$dir
  done
  printf '%s\n' "$out"
}
